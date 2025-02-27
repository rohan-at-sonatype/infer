(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open PulseBasicInterface
module L = Logging

type value = AbstractValue.t [@@deriving compare, equal]

type event =
  | ArrayWrite of {aw_array: value; aw_index: value}
  | Call of {return: value option; arguments: value list; procname: Procname.t}
[@@deriving compare, equal]

let pp_comma_seq f xs = Pp.comma_seq ~print_env:Pp.text_break f xs

let pp_event f = function
  | ArrayWrite {aw_array; aw_index} ->
      Format.fprintf f "@[ArrayWrite %a[%a]@]" AbstractValue.pp aw_array AbstractValue.pp aw_index
  | Call {return; arguments; procname} ->
      let procname = Procname.hashable_name procname (* as in [static_match] *) in
      Format.fprintf f "@[call@ %a=%s(%a)@]" (Pp.option AbstractValue.pp) return procname
        (pp_comma_seq AbstractValue.pp) arguments


type vertex = ToplAutomaton.vindex [@@deriving compare, equal]

type register = ToplAst.register_name [@@deriving compare, equal]

type configuration = {vertex: vertex; memory: (register * value) list} [@@deriving compare, equal]

type substitution = (AbstractValue.t * ValueHistory.t) AbstractValue.Map.t

type 'a substitutor = substitution * 'a -> substitution * 'a

let sub_value (sub, value) =
  match AbstractValue.Map.find_opt value sub with
  | Some (v, _history) ->
      (sub, v)
  | None ->
      let v = AbstractValue.mk_fresh () in
      let sub = AbstractValue.Map.add value (v, ValueHistory.epoch) sub in
      (sub, v)


let sub_list : 'a substitutor -> 'a list substitutor =
 fun sub_elem (sub, xs) ->
  let f (sub, xs) x =
    let sub, x = sub_elem (sub, x) in
    (sub, x :: xs)
  in
  let sub, xs = List.fold ~init:(sub, []) ~f xs in
  (sub, List.rev xs)


module Constraint : sig
  type predicate

  type t [@@deriving compare, equal]

  val make : Binop.t -> Formula.operand -> Formula.operand -> predicate

  val true_ : t

  val and_predicate : predicate -> t -> t

  val and_constr : t -> t -> t

  val and_n : t list -> t

  val normalize : t -> t

  val negate : t list -> t list
  (** computes ¬(c1∨...∨cm) as d1∨...∨dn, where n=|c1|x...x|cm| *)

  val eliminate_exists : keep:AbstractValue.Set.t -> t -> t
  (** quantifier elimination *)

  val size : t -> int

  val substitute : t substitutor

  val prune_path : t -> Formula.t -> Formula.t SatUnsat.t

  val pp : Format.formatter -> t -> unit
end = struct
  type predicate = Binop.t * Formula.operand * Formula.operand [@@deriving compare, equal]

  type t = predicate list [@@deriving compare, equal]

  let make binop lhs rhs = (binop, lhs, rhs)

  let true_ = []

  let is_trivially_true (predicate : predicate) =
    match predicate with
    | Eq, AbstractValueOperand l, AbstractValueOperand r when AbstractValue.equal l r ->
        true
    | _ ->
        false


  let and_predicate predicate constr =
    if is_trivially_true predicate then constr else predicate :: constr


  let and_constr constr_a constr_b = List.rev_append constr_a constr_b

  let and_n constraints = List.concat_no_order constraints

  let normalize constr = List.dedup_and_sort ~compare:compare_predicate constr

  let negate_predicate (predicate : predicate) : predicate =
    match predicate with
    | Eq, l, r ->
        (Ne, l, r)
    | Ne, l, r ->
        (Eq, l, r)
    | Ge, l, r ->
        (Lt, r, l)
    | Gt, l, r ->
        (Le, r, l)
    | Le, l, r ->
        (Gt, r, l)
    | Lt, l, r ->
        (Ge, r, l)
    | _ ->
        L.die InternalError
          "PulseTopl.negate_predicate should handle all outputs of PulseTopl.binop_to"


  let negate disjunction = IList.product (List.map ~f:(List.map ~f:negate_predicate) disjunction)

  let size constr = List.length constr

  let substitute_predicate (sub, predicate) =
    let avo x : Formula.operand = AbstractValueOperand x in
    match (predicate : predicate) with
    | op, AbstractValueOperand l, AbstractValueOperand r ->
        let sub, l = sub_value (sub, l) in
        let sub, r = sub_value (sub, r) in
        (sub, (op, avo l, avo r))
    | op, AbstractValueOperand l, r ->
        let sub, l = sub_value (sub, l) in
        (sub, (op, avo l, r))
    | op, l, AbstractValueOperand r ->
        let sub, r = sub_value (sub, r) in
        (sub, (op, l, avo r))
    | _ ->
        (sub, predicate)


  let substitute = sub_list substitute_predicate

  let prune_path constr path_condition =
    let open SatUnsat.Import in
    let f path_condition (op, l, r) =
      Formula.prune_binop ~negated:false op l r path_condition >>| fst
    in
    SatUnsat.list_fold ~init:path_condition ~f constr


  let pp_predicate f (op, l, r) =
    Format.fprintf f "@[%a%a%a@]" PulseFormula.pp_operand l Binop.pp op PulseFormula.pp_operand r


  let pp = Pp.seq ~sep:"∧" pp_predicate

  let eliminate_exists ~keep constr =
    (* TODO(rgrigore): replace the current weak approximation *)
    let is_live_operand : PulseFormula.operand -> bool = function
      | AbstractValueOperand v ->
          AbstractValue.Set.mem v keep
      | ConstOperand _ ->
          true
      | FunctionApplicationOperand _ ->
          true
    in
    let is_live_predicate (_op, l, r) = is_live_operand l && is_live_operand r in
    List.filter ~f:is_live_predicate constr
end

type predicate = Binop.t * Formula.operand * Formula.operand [@@deriving compare]

type step =
  { step_location: Location.t
  ; step_predecessor: simple_state  (** state before this step *)
  ; step_data: step_data }

and step_data = SmallStep of event | LargeStep of (Procname.t * (* post *) simple_state)

and simple_state =
  { pre: configuration  (** at the start of the procedure *)
  ; post: configuration  (** at the current program point *)
  ; pruned: Constraint.t  (** path-condition for the automaton *)
  ; last_step: step option [@ignore]  (** for trace error reporting *) }
[@@deriving compare, equal]

(* TODO: include a hash of the automaton in a summary to avoid caching problems. *)
(* TODO: limit the number of simple_states to some configurable number (default ~5) *)
type state = simple_state list [@@deriving compare, equal]

let pp_mapping f (x, value) = Format.fprintf f "@[%s↦%a@]@," x AbstractValue.pp value

let pp_memory f memory = Format.fprintf f "@[<2>[%a]@]" (pp_comma_seq pp_mapping) memory

let pp_configuration f {vertex; memory} =
  Format.fprintf f "@[{ topl-config@;vertex=%d@;memory=%a }@]" vertex pp_memory memory


let pp_simple_state f {pre; post; pruned} =
  Format.fprintf f "@[<2>{ topl-simple-state@;pre=%a@;post=%a@;pruned=(%a) }@]" pp_configuration pre
    pp_configuration post Constraint.pp pruned


let pp_state f state =
  Format.fprintf f "@[<v2>{len=%d;content=@;@[<2>[ %a ]@]}@]" (List.length state)
    (pp_comma_seq pp_simple_state) state


let start () =
  let mk_simple_states () =
    let a = Topl.automaton () in
    let memory =
      List.map ~f:(fun r -> (r, AbstractValue.mk_fresh ())) (ToplAutomaton.registers a)
    in
    let configurations =
      let n = ToplAutomaton.vcount a in
      let f acc vertex = {vertex; memory} :: acc in
      IContainer.forto n ~init:[] ~f
    in
    List.map
      ~f:(fun c -> {pre= c; post= c; pruned= Constraint.true_; last_step= None})
      configurations
  in
  if Topl.is_active () then mk_simple_states () else (* Avoids work later *) []


let get env x =
  match List.Assoc.find env ~equal:String.equal x with
  | Some v ->
      v
  | None ->
      L.die InternalError "Topl: Cannot find %s. Should be caught by static checks" x


let set = List.Assoc.add ~equal:String.equal

let binop_to : ToplAst.binop -> Binop.t = function
  | OpEq ->
      Eq
  | OpNe ->
      Ne
  | OpGe ->
      Ge
  | OpGt ->
      Gt
  | OpLe ->
      Le
  | OpLt ->
      Lt


let eval_guard memory tcontext guard : Constraint.t =
  let operand_of_value (value : ToplAst.value) : Formula.operand =
    match value with
    | Constant (LiteralInt x) ->
        ConstOperand (Cint (IntLit.of_int x))
    | Register reg ->
        AbstractValueOperand (get memory reg)
    | Binding v ->
        AbstractValueOperand (get tcontext v)
  in
  let conjoin_predicate pruned (predicate : ToplAst.predicate) =
    match predicate with
    | Binop (binop, l, r) ->
        let l = operand_of_value l in
        let r = operand_of_value r in
        let binop = binop_to binop in
        Constraint.and_predicate (Constraint.make binop l r) pruned
    | Value v ->
        let v = operand_of_value v in
        let one = Formula.ConstOperand (Cint IntLit.one) in
        Constraint.and_predicate (Constraint.make Binop.Ne v one) pruned
  in
  List.fold ~init:Constraint.true_ ~f:conjoin_predicate guard


let apply_action tcontext assignments memory =
  let apply_one memory (register, variable) = set memory register (get tcontext variable) in
  List.fold ~init:memory ~f:apply_one assignments


type tcontext = (ToplAst.variable_name * AbstractValue.t) list

let pp_tcontext f tcontext =
  Format.fprintf f "@[[%a]@]" (pp_comma_seq (Pp.pair ~fst:String.pp ~snd:AbstractValue.pp)) tcontext


let static_match_array_write arr index label : tcontext option =
  match label.ToplAst.pattern with
  | ArrayWritePattern ->
      let v1, v2 =
        match label.ToplAst.arguments with
        | Some [v1; v2] ->
            (v1, v2)
        | _ ->
            L.die InternalError "Topl: #ArrayWrite should have exactly two arguments"
      in
      Some [(v1, arr); (v2, index)]
  | _ ->
      None


let static_match_call return arguments procname label : tcontext option =
  let rev_arguments = List.rev arguments in
  let procname = Procname.hashable_name procname in
  let match_name () : bool =
    match label.ToplAst.pattern with
    | ProcedureNamePattern pname ->
        Str.string_match (Str.regexp pname) procname 0
    | _ ->
        false
  in
  let match_args () : tcontext option =
    let match_formals formals : tcontext option =
      let bind ~init rev_formals =
        let f tcontext variable value = (variable, value) :: tcontext in
        match List.fold2 ~init ~f rev_formals rev_arguments with
        | Ok c ->
            Some c
        | Unequal_lengths ->
            None
      in
      match (List.rev formals, return) with
      | [], Some _ ->
          None
      | rev_formals, None ->
          bind ~init:[] rev_formals
      | r :: rev_formals, Some v ->
          bind ~init:[(r, v)] rev_formals
    in
    Option.value_map ~default:(Some []) ~f:match_formals label.ToplAst.arguments
  in
  if match_name () then match_args () else None


module Debug = struct
  let rec matched_transitions =
    lazy
      ( Epilogues.register ~f:log_unseen
          ~description:"log which transitions never match because of their static pattern" ;
        let automaton = Topl.automaton () in
        let tcount = ToplAutomaton.tcount automaton in
        Array.create ~len:tcount false )


  and set_seen tindex = (Lazy.force matched_transitions).(tindex) <- true

  and get_unseen () =
    let f index seen = if seen then None else Some index in
    Array.filter_mapi ~f (Lazy.force matched_transitions)


  (** The transitions reported here *probably* have patterns that were miswrote by the user. *)
  and log_unseen () =
    let unseen = Array.to_list (get_unseen ()) in
    let pp f i = ToplAutomaton.pp_tindex (Topl.automaton ()) f i in
    if Config.trace_topl && not (List.is_empty unseen) then
      L.user_warning "@[<v>@[<v2>The following Topl transitions never match:@;%a@]@;@]"
        (Format.pp_print_list pp) unseen


  let dropped_disjuncts_count = ref 0
end

(** Returns a list of transitions whose pattern matches (e.g., event type matches). Each match
    produces a tcontext (transition context), which matches transition-local variables to abstract
    values. *)
let static_match event : (ToplAutomaton.transition * tcontext) list =
  let match_one index transition =
    let f label =
      match event with
      | ArrayWrite {aw_array; aw_index} ->
          static_match_array_write aw_array aw_index label
      | Call {return; arguments; procname} ->
          static_match_call return arguments procname label
    in
    let tcontext_opt = Option.value_map ~default:(Some []) ~f transition.ToplAutomaton.label in
    L.d_printfln "@[<2>PulseTopl.static_match:@;transition %a@;event %a@;result %a@]"
      (ToplAutomaton.pp_transition (Topl.automaton ()))
      transition pp_event event (Pp.option pp_tcontext) tcontext_opt ;
    Option.map
      ~f:(fun tcontext ->
        Debug.set_seen index ;
        (transition, tcontext) )
      tcontext_opt
  in
  ToplAutomaton.tfilter_mapi (Topl.automaton ()) ~f:match_one


let is_unsat = function SatUnsat.Unsat -> true | SatUnsat.Sat _ -> false

let is_unsat_cheap path_condition pruned = Constraint.prune_path pruned path_condition |> is_unsat

let default_tenv = Tenv.create ()

let is_unsat_expensive ~get_dynamic_type path_condition pruned =
  let open SatUnsat.Import in
  Constraint.prune_path pruned path_condition
  >>= Formula.normalize default_tenv ~get_dynamic_type
  |> is_unsat


let drop_infeasible ?(expensive = false) ~get_dynamic_type ~path_condition state =
  let is_unsat = if expensive then is_unsat_expensive ~get_dynamic_type else is_unsat_cheap in
  let f {pruned} = not (is_unsat path_condition pruned) in
  List.filter ~f state


let normalize_memory memory = List.sort ~compare:[%compare: register * value] memory

let normalize_configuration {vertex; memory} = {vertex; memory= normalize_memory memory}

let normalize_simple_state {pre; post; pruned; last_step} =
  { pre= normalize_configuration pre
  ; post= normalize_configuration post
  ; pruned= Constraint.normalize pruned
  ; last_step }


let normalize_state state = List.map ~f:normalize_simple_state state

(** Filters out simple states that cannot reach error because their registers refer to garbage.

    - "Garbage" is a value unreachable from the program state and different from all vlaues held by
      registers in the pre-simple-state.
    - The current implementation is an approximation. If a register refers to garbage, it might
      still be the case that "error" could be reached, depending on the structure of the automaton.
      This could be determined by a pre-analysis of the automaton. However, because such cases are
      empirically rare, we just under-approximate by dropping always when a register has garbage.
    - We never drop simple-states corresponding to "error" vertices. *)
let drop_garbage ~keep state =
  let should_keep {pre; post} =
    ToplAutomaton.is_error (Topl.automaton ()) post.vertex
    ||
    let add_register values (_register, v) = AbstractValue.Set.add v values in
    let ok = List.fold ~f:add_register ~init:keep pre.memory in
    let register_is_ok (_register, v) = AbstractValue.Set.mem v ok in
    List.for_all ~f:register_is_ok post.memory
  in
  List.filter ~f:should_keep state


let simplify ~keep ~get_dynamic_type ~path_condition state =
  let simplify_simple_state {pre; post; pruned; last_step} =
    (* NOTE: We do not consider registers live. If the Topl monitor has a hold of something that is
       garbage for the program, then that something is still garbage. *)
    let collect memory keep =
      List.fold ~init:keep ~f:(fun keep (_reg, value) -> AbstractValue.Set.add value keep) memory
    in
    let keep = keep |> collect pre.memory |> collect post.memory in
    let pruned = Constraint.eliminate_exists ~keep pruned in
    L.d_printfln "@[<2>PulseTopl.simplify@;before=%a@;after=%a@]" Constraint.pp pruned Constraint.pp
      pruned ;
    {pre; post; pruned; last_step}
  in
  (* The following three steps are ordered from fastest to slowest. *)
  let state = List.map ~f:simplify_simple_state state in
  let state = drop_garbage ~keep state in
  let state = drop_infeasible ~expensive:true ~get_dynamic_type ~path_condition state in
  List.dedup_and_sort ~compare:compare_simple_state state


let apply_limits ~keep ~get_dynamic_type ~path_condition state =
  let expensive_simplification state = simplify ~keep ~get_dynamic_type ~path_condition state in
  let drop_disjuncts state =
    let old_len = List.length state in
    let new_len = (Config.topl_max_disjuncts / 2) + 1 in
    if Config.trace_topl then
      Debug.dropped_disjuncts_count := !Debug.dropped_disjuncts_count + old_len - new_len ;
    let add_score simple_state =
      let score = Constraint.size simple_state.pruned in
      if score > Config.topl_max_conjuncts then None else Some (score, simple_state)
    in
    let strip_score = snd in
    let compare_score (score1, _simple_state1) (score2, _simple_state2) =
      Int.compare score1 score2
    in
    state |> List.filter_map ~f:add_score |> List.sort ~compare:compare_score
    |> Fn.flip List.take new_len |> List.map ~f:strip_score
  in
  let needs_shrinking state = List.length state > Config.topl_max_disjuncts in
  let maybe condition transform x = if condition x then transform x else x in
  state |> maybe needs_shrinking expensive_simplification |> maybe needs_shrinking drop_disjuncts


let small_step loc ~keep ~get_dynamic_type ~path_condition event simple_states =
  let tmatches = static_match event in
  let evolve_transition (old : simple_state) (transition, tcontext) : state =
    let mk ?(memory = old.post.memory) ?(pruned = Constraint.true_) significant =
      let last_step =
        if significant then
          Some {step_location= loc; step_predecessor= old; step_data= SmallStep event}
        else old.last_step
      in
      (* NOTE: old pruned is discarded, because evolve_simple_state needs to see only new prunes
         to determine skip transitions. It will then add back old prunes. *)
      let post = {vertex= transition.ToplAutomaton.target; memory} in
      {old with post; pruned; last_step}
    in
    match transition.ToplAutomaton.label with
    | None ->
        (* "any" transition *)
        let is_loop = Int.equal transition.ToplAutomaton.source transition.ToplAutomaton.target in
        [mk (not is_loop)]
    | Some label ->
        let memory = old.post.memory in
        let pruned = eval_guard memory tcontext label.ToplAst.condition in
        let memory = apply_action tcontext label.ToplAst.action memory in
        [mk ~memory ~pruned true]
  in
  let evolve_simple_state old =
    let tmatches =
      List.filter ~f:(fun (t, _) -> Int.equal old.post.vertex t.ToplAutomaton.source) tmatches
    in
    let nonskip = List.concat_map ~f:(evolve_transition old) tmatches in
    let skip =
      let nonskip_disjunction = List.map ~f:(fun {pruned} -> pruned) nonskip in
      let skip_disjunction = Constraint.negate nonskip_disjunction in
      let f pruned = {old with pruned} (* keeps last_step from old *) in
      List.map ~f skip_disjunction
    in
    let add_old_pruned s = {s with pruned= Constraint.and_constr s.pruned old.pruned} in
    List.map ~f:add_old_pruned (List.rev_append nonskip skip)
  in
  let result = List.concat_map ~f:evolve_simple_state simple_states in
  L.d_printfln "@[<2>PulseTopl.small_step:@;%a@ -> %a@]" pp_state simple_states pp_state result ;
  result |> apply_limits ~keep ~get_dynamic_type ~path_condition


let of_unequal (or_unequal : 'a List.Or_unequal_lengths.t) =
  match or_unequal with
  | Ok x ->
      x
  | Unequal_lengths ->
      L.die InternalError "PulseTopl expected lists to be of equal lengths"


let sub_configuration (sub, {vertex; memory}) =
  let keys, values = List.unzip memory in
  let sub, values = sub_list sub_value (sub, values) in
  let memory = of_unequal (List.zip keys values) in
  (sub, {vertex; memory})


(* Does not substitute in [last_step]: not usually needed, and takes much time. *)
let sub_simple_state (sub, {pre; post; pruned; last_step}) =
  let sub, pre = sub_configuration (sub, pre) in
  let sub, post = sub_configuration (sub, post) in
  let sub, pruned = Constraint.substitute (sub, pruned) in
  (sub, {pre; post; pruned; last_step})


let large_step ~call_location ~callee_proc_name ~substitution ~keep ~get_dynamic_type
    ~path_condition ~callee_prepost state =
  let seq ((p : simple_state), (q : simple_state)) =
    if not (Int.equal p.post.vertex q.pre.vertex) then None
    else
      let substitution, new_eqs =
        (* Update the substitution, matching formals with actuals. We work a bit to avoid introducing
           equalities, because a growing [pruned] leads to quadratic behaviour. *)
        let mk_eq val1 val2 =
          let op x = Formula.AbstractValueOperand x in
          Constraint.make Binop.Eq (op val1) (op val2)
        in
        let f (sub, eqs) (reg1, val1) (reg2, val2) =
          if not (String.equal reg1 reg2) then
            L.die InternalError
              "PulseTopl: normalized memories are expected to have the same domain"
          else
            match AbstractValue.Map.find_opt val2 sub with
            | Some (old_val1, _history) ->
                if AbstractValue.equal old_val1 val1 then (sub, eqs)
                else (sub, Constraint.and_predicate (mk_eq old_val1 val1) eqs)
            | None ->
                (AbstractValue.Map.add val2 (val1, ValueHistory.epoch) sub, eqs)
        in
        of_unequal (List.fold2 p.post.memory q.pre.memory ~init:(substitution, Constraint.true_) ~f)
      in
      let _substitution, q = sub_simple_state (substitution, q) in
      let pruned = Constraint.and_n [new_eqs; q.pruned; p.pruned] in
      let last_step =
        Some
          { step_location= call_location
          ; step_predecessor= p
          ; step_data= LargeStep (callee_proc_name, q) }
      in
      Some {pre= p.pre; post= q.post; pruned; last_step}
  in
  (* TODO(rgrigore): may be worth optimizing the cartesian_product *)
  let state = normalize_state state in
  let callee_prepost = normalize_state callee_prepost in
  let result = List.filter_map ~f:seq (List.cartesian_product state callee_prepost) in
  L.d_printfln "@[<2>PulseTopl.large_step:@;callee_prepost=%a@;%a@ -> %a@]" pp_state callee_prepost
    pp_state state pp_state result ;
  result |> apply_limits ~keep ~get_dynamic_type ~path_condition


let filter_for_summary ~get_dynamic_type path_condition state =
  drop_infeasible ~get_dynamic_type ~expensive:true ~path_condition state


let description_of_step_data step_data =
  ( match step_data with
  | SmallStep (Call {procname}) | LargeStep (procname, _) ->
      Format.fprintf Format.str_formatter "@[call to %a@]" Procname.pp procname
  | SmallStep (ArrayWrite _) ->
      Format.fprintf Format.str_formatter "@[write to array@]" ) ;
  Format.flush_str_formatter ()


let report_errors proc_desc err_log state =
  let a = Topl.automaton () in
  let rec make_trace nesting trace q =
    match q.last_step with
    | None ->
        trace
    | Some {step_location; step_predecessor; step_data} ->
        let description = description_of_step_data step_data in
        let trace =
          let trace_element = Errlog.make_trace_element nesting step_location description [] in
          match step_data with
          | SmallStep _ ->
              trace_element :: trace
          | LargeStep (_, qq) ->
              let new_trace = make_trace (nesting + 1) trace qq in
              (* Skip trivial large steps (those with no substeps) *)
              if phys_equal new_trace trace then trace else trace_element :: new_trace
        in
        make_trace nesting trace step_predecessor
  in
  let rec first_error_ss q =
    match q.last_step with
    | Some {step_predecessor} ->
        if not (ToplAutomaton.is_error a step_predecessor.post.vertex) then q
        else first_error_ss step_predecessor
    | None ->
        L.die InternalError "PulseTopl.report_errors inv broken"
  in
  let is_nested_large_step q =
    match q.last_step with
    | Some {step_data= LargeStep (_, prepost)}
      when ToplAutomaton.is_start a prepost.pre.vertex
           && ToplAutomaton.is_error a prepost.post.vertex ->
        true
    | _ ->
        false
  in
  let report_simple_state q =
    if ToplAutomaton.is_start a q.pre.vertex && ToplAutomaton.is_error a q.post.vertex then
      let q = first_error_ss q in
      (* Only report at the innermost level where error appears. *)
      if not (is_nested_large_step q) then
        let loc = Procdesc.get_loc proc_desc in
        let ltr = make_trace 0 [] q in
        let message = ToplAutomaton.message a q.post.vertex in
        Reporting.log_issue proc_desc err_log ~loc ~ltr Topl IssueType.topl_error message
  in
  List.iter ~f:report_simple_state state
