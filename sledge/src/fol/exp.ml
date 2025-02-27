(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type var = Var.t
type trm = Trm.t [@@deriving compare, equal, sexp]
type fml = Fml.t [@@deriving compare, equal, sexp]

(** Conditional terms, denoting functions from structures to values, taking
    the form of trees with internal nodes labeled with formulas and leaves
    labeled with terms. *)
type cnd = [`Ite of fml * cnd * cnd | `Trm of trm]
[@@deriving compare, equal, sexp]

(** Expressions, which are partitioned into terms, conditional terms, and
    formulas. *)
type exp = [cnd | `Fml of fml] [@@deriving compare, equal, sexp]

let pp_boxed fs fmt =
  Format.pp_open_box fs 2 ;
  Format.kfprintf (fun fs -> Format.pp_close_box fs ()) fs fmt

let ppx_cnd strength fs ct =
  let pp_t = Trm.ppx strength in
  let pp_f = Fml.ppx strength in
  let rec pp fs ct =
    let pf fmt = pp_boxed fs fmt in
    match ct with
    | `Ite (cnd, thn, els) -> pf "(%a@ ? %a@ : %a)" pp_f cnd pp thn pp els
    | `Trm t -> pp_t fs t
  in
  pp fs ct

let ppx strength fs = function
  | #cnd as c -> ppx_cnd strength fs c
  | `Fml f -> Fml.ppx strength fs f

let pp = ppx (fun _ -> None)

(*
 * Core construction functions
 *
 * Support functions for constructing expressions as if terms and formulas
 * could be freely mixed, instead of being strictly partitioned into terms
 * and formulas stratified below conditional terms and then expressions.
 *)

let _Ite cnd thn els =
  match (cnd : Fml.t) with
  (* (tt ? t : e) ==> t *)
  | Tt -> thn
  (* (ff ? t : e) ==> e *)
  | Not Tt -> els
  (* (c ? t : t) ==> t *)
  | _ when equal_cnd thn els -> thn
  (* (¬c ? t : e) ==> (c ? e : t) *)
  | _ when Fml.is_negative cnd -> `Ite (Fml.not_ cnd, els, thn)
  | _ -> `Ite (cnd, thn, els)

(** Embed a formula into a conditional term (associating true with 1 and
    false with 0), identity on conditional terms. *)
let embed_into_cnd : exp -> cnd = function
  | #cnd as c -> c
  (* p ==> (p ? 1 : 0) *)
  | `Fml fml -> _Ite fml (`Trm Trm.one) (`Trm Trm.zero)

(** Project out a formula that is embedded into a conditional term.

    - [project_out_fml] is left inverse to [embed_into_cnd] in the sense
      that [project_out_fml (embed_into_cnd (`Fml f)) = Some f]. *)
let project_out_fml : cnd -> fml option = function
  (* (p ? 1 : 0) ==> p *)
  | `Ite (cnd, `Trm one', `Trm zero')
    when Trm.one == one' && Trm.zero == zero' ->
      Some cnd
  | _ -> None

(** Construct a conditional formula. *)
let cond cnd pos neg = Fml.cond ~cnd ~pos ~neg

(** Construct a conditional term, or formula if possible precisely. *)
let ite : fml -> exp -> exp -> exp =
 fun cnd thn els ->
  match (thn, els) with
  | `Fml pos, `Fml neg -> `Fml (cond cnd pos neg)
  | _ -> (
      let c = _Ite cnd (embed_into_cnd thn) (embed_into_cnd els) in
      match project_out_fml c with Some f -> `Fml f | None -> (c :> exp) )

(** Map a unary function on terms over the leaves of a conditional term,
    rebuilding the tree of conditionals with the supplied ite construction
    function. *)
let rec map_cnd : (fml -> 'a -> 'a -> 'a) -> (trm -> 'a) -> cnd -> 'a =
 fun f_ite f_trm -> function
  | `Trm trm -> f_trm trm
  | `Ite (cnd, thn, els) ->
      let thn' = map_cnd f_ite f_trm thn in
      let els' = map_cnd f_ite f_trm els in
      f_ite cnd thn' els'

(** Map a unary function on terms over an expression. *)
let ap1 : (trm -> exp) -> exp -> exp =
 fun f x -> map_cnd ite f (embed_into_cnd x)

let ap1t : (trm -> trm) -> exp -> exp = fun f -> ap1 (fun x -> `Trm (f x))

let ap1f : (trm -> fml) -> exp -> fml =
 fun f x -> map_cnd cond f (embed_into_cnd x)

(** Map a binary function on terms over conditional terms. This yields a
    conditional tree with the structure from the first argument where each
    leaf has been replaced by a conditional tree with the structure from the
    second argument where each leaf has been replaced by the application of
    the argument binary function to the corresponding leaves from the first
    and second argument. *)
let map2_cnd :
    (fml -> 'a -> 'a -> 'a) -> (trm -> trm -> 'a) -> cnd -> cnd -> 'a =
 fun f_ite f_trm x y ->
  map_cnd f_ite (fun x' -> map_cnd f_ite (fun y' -> f_trm x' y') y) x

(** Map a binary function on terms over expressions. *)
let ap2 : (trm -> trm -> exp) -> exp -> exp -> exp =
 fun f x y -> map2_cnd ite f (embed_into_cnd x) (embed_into_cnd y)

let ap2t : (trm -> trm -> trm) -> exp -> exp -> exp =
 fun f -> ap2 (fun x y -> `Trm (f x y))

let ap2f : (trm -> trm -> fml) -> exp -> exp -> fml =
 fun f x y -> map2_cnd cond f (embed_into_cnd x) (embed_into_cnd y)

let map4_cnd f_ite f_trm w x y z =
  map_cnd f_ite
    (fun w' ->
      map_cnd f_ite
        (fun x' ->
          map_cnd f_ite
            (fun y' -> map_cnd f_ite (fun z' -> f_trm w' x' y' z') z)
            y )
        x )
    w

let ap4 f w x y z =
  map4_cnd ite f (embed_into_cnd w) (embed_into_cnd x) (embed_into_cnd y)
    (embed_into_cnd z)

let ap4t f = ap4 (fun w x y z -> `Trm (f w x y z))

(** Reverse-map an nary function on terms over conditional terms. *)
let rev_mapN_cnd :
    (fml -> 'a -> 'a -> 'a) -> (trm list -> 'a) -> cnd list -> 'a =
 fun f_ite f_trms rev_xs ->
  let rec loop xs' = function
    | x :: xs -> map_cnd f_ite (fun x' -> loop (x' :: xs') xs) x
    | [] -> f_trms xs'
  in
  loop [] rev_xs

(** Map an nary function on terms over expressions. *)
let apNt : (trm array -> trm) -> exp array -> exp =
 fun f xs ->
  rev_mapN_cnd ite
    (fun xs -> `Trm (f (Array.of_list xs)))
    (Array.to_list_rev_map ~f:embed_into_cnd xs)

let apNf : (trm array -> fml) -> exp array -> fml =
 fun f xs ->
  rev_mapN_cnd cond
    (fun xs -> f (Array.of_list xs))
    (Array.to_list_rev_map ~f:embed_into_cnd xs)

(** Size-tagged sequence *)
module Sized = struct
  type sized = {seq: exp; siz: exp}

  let map_sized : (Trm.sized -> 'a) -> sized -> 'a =
   fun f {seq; siz} ->
    map2_cnd ite
      (fun seq siz -> f {Trm.seq; siz})
      (embed_into_cnd seq) (embed_into_cnd siz)

  let rev_mapN_sized : (Trm.sized list -> 'a) -> sized list -> 'a =
   fun f_trms rev_xs ->
    let rec loop xs' = function
      | x :: xs -> map_sized (fun x' -> loop (x' :: xs') xs) x
      | [] -> f_trms xs'
    in
    loop [] rev_xs

  let apN_sized : (Trm.sized array -> trm) -> sized array -> exp =
   fun f xs ->
    rev_mapN_sized
      (fun xs -> `Trm (f (Array.of_list xs)))
      (Array.to_list_rev xs)
end

(*
 * Encode
 *)

(* The SLEdge internal logic is unsorted, while Z3 requires sorts. Therefore
   this encoding treats every element of the universe as a rational/real
   number. This causes the interpretation of arithmetic inequality to be not
   entirely correct. Also, terms representing byte-arrays/sequences are left
   uninterpreted. *)

module ToZ3 = struct
  let integer x (z : Z.t) =
    match Z.to_int z with
    | n -> Z3.Expr.mk_numeral_int x n (Z3.Arithmetic.Real.mk_sort x)
    | exception Z.Overflow ->
        Z3.Expr.mk_numeral_string x (Z.to_string z)
          (Z3.Arithmetic.Real.mk_sort x)

  let rational x (q : Q.t) =
    match (Z.to_int q.num, Z.to_int q.den) with
    | n, d -> Z3.Arithmetic.Real.mk_numeral_nd x n d
    | exception Z.Overflow ->
        Z3.Expr.mk_numeral_string x (Q.to_string q)
          (Z3.Arithmetic.Real.mk_sort x)

  let rec trm x e =
    match (e : trm) with
    | Var {id; name= _} ->
        let sym =
          if 0 <= id && id < 1 lsl 30 then Z3.Symbol.mk_int x id
          else Z3.Symbol.mk_string x (string_of_int id)
        in
        Z3.Expr.mk_const x sym (Z3.Arithmetic.Real.mk_sort x)
    | Z z -> integer x z
    | Q q -> rational x q
    | Arith a ->
        let pow (b, p) =
          Z3.Arithmetic.mk_power x (trm x b)
            (Z3.Expr.mk_numeral_int x p (Z3.Arithmetic.Integer.mk_sort x))
        in
        let mono (c, m) =
          Z3.Arithmetic.mk_mul x
            (rational x c :: Iter.to_list (Iter.map ~f:pow m))
        in
        let poly p =
          Z3.Arithmetic.mk_add x (Iter.to_list (Iter.map ~f:mono p))
        in
        poly (Trm.Arith.sum_of_power_products a)
    | Splat e ->
        let sort = Z3.Arithmetic.Real.mk_sort x in
        Z3.Expr.mk_app x
          (Z3.FuncDecl.mk_func_decl_s x "splat" [sort] sort)
          [trm x e]
    | Extract {seq; siz; off; len} ->
        let sort = Z3.Arithmetic.Real.mk_sort x in
        Z3.Expr.mk_app x
          (Z3.FuncDecl.mk_func_decl_s x "extract" [sort; sort; sort; sort]
             sort )
          [trm x seq; trm x siz; trm x off; trm x len]
    | Concat nas ->
        let sort = Z3.Arithmetic.Real.mk_sort x in
        let concat =
          Z3.FuncDecl.mk_func_decl_s x "concat" [sort; sort; sort] sort
        in
        let empty = Z3.Expr.mk_const_s x "empty" sort in
        Array.fold_right nas empty ~f:(fun {seq; siz} agg ->
            Z3.Expr.mk_app x concat [trm x seq; trm x siz; agg] )
    | Apply (f, es) ->
        let sort = Z3.Arithmetic.Real.mk_sort x in
        let fsym =
          Z3.FuncDecl.mk_func_decl_s x
            (Sexp.to_string (Funsym.sexp_of_t f))
            (List.init (Array.length es) ~f:(fun _ -> sort))
            sort
        in
        Z3.Expr.mk_app x fsym
          (Iter.to_list (Iter.map ~f:(trm x) (Array.to_iter es)))

  let rec fml x b =
    match (b : fml) with
    | Tt -> Z3.Boolean.mk_true x
    | Eq (d, e) -> Z3.Boolean.mk_eq x (trm x d) (trm x e)
    | Distinct es ->
        Z3.Boolean.mk_distinct x
          (Iter.to_list (Iter.map ~f:(trm x) (Array.to_iter es)))
    | Eq0 e ->
        Z3.Boolean.mk_eq x (trm x e)
          (Z3.Expr.mk_numeral_int x 0 (Z3.Arithmetic.Real.mk_sort x))
    | Pos e ->
        Z3.Arithmetic.mk_gt x (trm x e)
          (Z3.Expr.mk_numeral_int x 0 (Z3.Arithmetic.Real.mk_sort x))
    | Not a -> Z3.Boolean.mk_not x (fml x a)
    | And {pos; neg} -> Z3.Boolean.mk_and x (pos_neg_fml x ~pos ~neg)
    | Or {pos; neg} -> Z3.Boolean.mk_or x (pos_neg_fml x ~pos ~neg)
    | Iff (a, b) -> Z3.Boolean.mk_iff x (fml x a) (fml x b)
    | Cond {cnd; pos; neg} ->
        Z3.Boolean.mk_ite x (fml x cnd) (fml x pos) (fml x neg)
    | Lit (p, es) ->
        let sort = Z3.Arithmetic.Real.mk_sort x in
        let psym =
          Z3.FuncDecl.mk_func_decl_s x
            (Sexp.to_string (Predsym.sexp_of_t p))
            (List.init (Array.length es) ~f:(fun _ -> sort))
            sort
        in
        Z3.Expr.mk_app x psym
          (Iter.to_list (Iter.map ~f:(trm x) (Array.to_iter es)))

  and pos_neg_fml x ~pos ~neg =
    Fml.fold_pos_neg ~pos ~neg ~f:(fun a bs -> fml x a :: bs) []

  let rec cnd x = function
    | `Trm t -> trm x t
    | `Ite (b, p, n) -> Z3.Boolean.mk_ite x (fml x b) (cnd x p) (cnd x n)

  let exp x = function `Fml f -> fml x f | #cnd as c -> cnd x c
end

(*
 * Terms: exposed interface
 *)

module Term = struct
  (* Exposed terms are represented as expressions, which allow formulas to
     appear at toplevel, although semantically these are redundant with
     their [inject]ion into [trm] proper. This redundancy of representation
     is allowed in order to avoid churning formulas back and forth between
     [fml] and [cnd] via [inject] and [project] in cases where formulas only
     transiently pass through term contexts. The construction functions will
     convert such a formula [p] into [(p ? 1 : 0)] as soon as it is used as
     a subterm, so this redundancy is only lazily delaying normalization by
     one step. *)
  module T = struct
    type t = exp [@@deriving compare, equal, sexp]

    let ppx = ppx
    let pp = pp
  end

  include T
  include Sized
  module Set = Set.Make (T)
  module Map = Map.Make (T)

  (* variables *)

  let var v = `Trm (v : var :> trm)

  (* arithmetic *)

  let zero = `Trm Trm.zero
  let one = `Trm Trm.one
  let integer z = `Trm (Trm.integer z)
  let rational q = `Trm (Trm.rational q)
  let neg = ap1t Trm.neg
  let add = ap2t Trm.add
  let sub = ap2t Trm.sub
  let mulq q = ap1t (Trm.mulq q)
  let mul = ap2t Trm.mul
  let div = ap2t Trm.div
  let pow x i = (ap1t @@ fun x -> Trm.pow x i) x

  (* sequences *)

  let splat = ap1t Trm.splat

  let extract ~seq ~siz ~off ~len =
    ap4t
      (fun seq siz off len -> Trm.extract ~seq ~siz ~off ~len)
      seq siz off len

  let concat elts = apN_sized Trm.concat elts

  (* uninterpreted *)

  let apply sym args = apNt (Trm.apply sym) args

  (* if-then-else *)

  let ite ~cnd ~thn ~els = ite cnd thn els

  (* Trm.t is embedded into Term.t *)
  let of_trm t = `Trm t
  let get_trm = function `Trm t -> Some t | _ -> None

  (** Destruct *)

  let get_z = function `Trm t -> Trm.get_z t | _ -> None
  let get_q = function `Trm t -> Trm.get_q t | _ -> None

  (** Access *)

  let split_const e =
    match (e : t) with
    | `Trm (Z z) -> (zero, Q.of_z z)
    | `Trm (Q q) -> (zero, q)
    | `Trm (Arith a) ->
        let a_c, c = Trm.Arith.split_const a in
        (`Trm (Trm.arith a_c), c)
    | e -> (e, Q.zero)

  (** Traverse *)

  let rec iter_trms_c c ~f =
    match c with
    | `Ite (cnd, thn, els) ->
        Iter.iter ~f (Fml.trms cnd) ;
        iter_trms_c ~f thn ;
        iter_trms_c ~f els
    | `Trm e -> f e

  let iter_trms e ~f =
    match e with
    | `Fml b -> Iter.iter ~f (Fml.trms b)
    | #cnd as c -> iter_trms_c ~f c

  let trms e = Iter.from_labelled_iter (iter_trms e)
  let vars e = Iter.flat_map ~f:Trm.vars (trms e)

  let atoms e =
    Iter.flat_map ~f:(fun t -> Iter.map ~f:of_trm (Trm.atoms t)) (trms e)

  (** Transform *)

  let rec map_vars_c ~f c =
    match c with
    | `Ite (cnd, thn, els) ->
        let cnd' = Fml.map_vars ~f cnd in
        let thn' = map_vars_c ~f thn in
        let els' = map_vars_c ~f els in
        if cnd' == cnd && thn' == thn && els' == els then c
        else _Ite cnd' thn' els'
    | `Trm t ->
        let t' = Trm.map_vars ~f t in
        if t' == t then c else `Trm t'

  let map_vars e ~f =
    match e with
    | `Fml p -> `Fml (Fml.map_vars ~f p)
    | #cnd as c -> (map_vars_c ~f c :> exp)

  let rec map_trms_c ~f c =
    match c with
    | `Ite (cnd, thn, els) ->
        let cnd' = Fml.map_trms ~f cnd in
        let thn' = map_trms_c ~f thn in
        let els' = map_trms_c ~f els in
        if cnd' == cnd && thn' == thn && els' == els then c
        else _Ite cnd' thn' els'
    | `Trm t ->
        let t' = f t in
        if t' == t then c else `Trm t'

  let map_trms e ~f =
    match e with
    | `Fml p -> `Fml (Fml.map_trms ~f p)
    | #cnd as c -> (map_trms_c ~f c :> exp)

  let fold_map_vars e s0 ~f =
    let s = ref s0 in
    let f x =
      let x', s' = f x !s in
      s := s' ;
      x'
    in
    let e' = map_vars ~f e in
    (e', !s)

  let rename s e = map_vars ~f:(Var.Subst.apply s) e

  (** Query *)

  let fv e = Var.Set.of_iter (vars e)

  (** Encode *)

  let to_z3 = ToZ3.exp
end

(*
 * Formulas: exposed interface
 *)

module Formula = struct
  include Fml

  let inject f = `Fml f
  let project = function `Fml f -> Some f | #cnd as c -> project_out_fml c

  (** Construct *)

  (* equality *)

  let eq = ap2f Fml.eq
  let dq a b = Fml.not_ (eq a b)
  let distinct = apNf Fml.distinct

  (* arithmetic *)

  let eq0 = ap1f Fml.eq0
  let dq0 a = Fml.not_ (eq0 a)
  let pos = ap1f Fml.pos

  (* a > b iff a-b > 0 iff 0 < a-b *)
  let gt a b = if b == Term.zero then pos a else pos (Term.sub a b)

  (* a ≥ b iff 0 ≥ b-a iff ¬(0 < b-a) *)
  let ge a b =
    if a == Term.zero then Fml.not_ (pos b)
    else Fml.not_ (pos (Term.sub b a))

  let lt a b = gt b a
  let le a b = ge b a

  (* uninterpreted *)

  let lit p es = apNf (Fml.lit p) es

  (* connectives *)

  let andN = function [] -> tt | b :: bs -> List.fold ~f:and_ bs b
  let orN = function [] -> ff | b :: bs -> List.fold ~f:or_ bs b
  let xor p q = Fml.not_ (iff p q)

  (** Query *)

  let fv p = Var.Set.of_iter (vars p)

  (** Transform *)

  let rec map_terms ~f b =
    let lift_map1 : (exp -> exp) -> t -> (trm -> t) -> trm -> t =
     fun f b cons x -> map1 f b (ap1f cons) (`Trm x)
    in
    let lift_map2 :
        (exp -> exp) -> t -> (trm -> trm -> t) -> trm -> trm -> t =
     fun f b cons x y -> map2 f b (ap2f cons) (`Trm x) (`Trm y)
    in
    let lift_mapN : (exp -> exp) -> t -> (trm array -> t) -> trm array -> t
        =
     fun f b cons xs ->
      mapN f b (apNf cons) (Array.map ~f:(fun x -> `Trm x) xs)
    in
    match b with
    | Tt -> b
    | Eq (x, y) -> lift_map2 f b Fml.eq x y
    | Distinct xs -> lift_mapN f b Fml.distinct xs
    | Eq0 x -> lift_map1 f b Fml.eq0 x
    | Pos x -> lift_map1 f b Fml.pos x
    | Not x -> map1 (map_terms ~f) b Fml.not_ x
    | And {pos; neg} -> Fml.map_and b ~pos ~neg (map_terms ~f)
    | Or {pos; neg} -> Fml.map_or b ~pos ~neg (map_terms ~f)
    | Iff (x, y) -> map2 (map_terms ~f) b Fml.iff x y
    | Cond {cnd; pos; neg} ->
        map3 (map_terms ~f) b
          (fun cnd pos neg -> Fml.cond ~cnd ~pos ~neg)
          cnd pos neg
    | Lit (p, xs) -> lift_mapN f b (Fml.lit p) xs

  let fold_map_vars e s0 ~f =
    let s = ref s0 in
    let f x =
      let x', s' = f x !s in
      s := s' ;
      x'
    in
    let e' = map_vars ~f e in
    (e', !s)

  let rename s e = map_vars ~f:(Var.Subst.apply s) e

  (** Encode *)

  let to_z3 = ToZ3.fml
end
