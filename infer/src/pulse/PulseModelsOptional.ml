(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open PulseBasicInterface
open PulseDomainInterface
open PulseOperationResult.Import
open PulseModelsImport

let internal_value = Fieldname.make PulseOperations.pulse_model_type "backing_value"

let internal_value_access = HilExp.Access.FieldAccess internal_value

let to_internal_value path mode location optional astate =
  PulseOperations.eval_access path mode location optional internal_value_access astate


let to_internal_value_deref path mode location optional astate =
  let* astate, pointer = to_internal_value path Read location optional astate in
  PulseOperations.eval_access path mode location pointer Dereference astate


let write_value path location this ~value ~desc astate =
  let* astate, value_field = to_internal_value path Read location this astate in
  let value_hist = (fst value, Hist.add_call path location desc (snd value)) in
  let+ astate = PulseOperations.write_deref path location ~ref:value_field ~obj:value_hist astate in
  (astate, value_field, value_hist)


let assign_value_fresh path location this ~desc astate =
  write_value path location this ~value:(AbstractValue.mk_fresh (), ValueHistory.epoch) ~desc astate


let assign_none this ~desc : model =
 fun {path; location} astate ->
  let<*> astate, pointer, value = assign_value_fresh path location this ~desc astate in
  let<**> astate = PulseArithmetic.and_eq_int (fst value) IntLit.zero astate in
  let<+> astate =
    PulseOperations.invalidate path
      (MemoryAccess {pointer; access= Dereference; hist_obj_default= snd value})
      location OptionalEmpty value astate
  in
  astate


let assign_value this _value ~desc : model =
 fun {path; location} astate ->
  (* TODO: call the copy constructor of a value *)
  let<*> astate, _, value = assign_value_fresh path location this ~desc astate in
  let<++> astate = PulseArithmetic.and_positive (fst value) astate in
  astate


let assign_optional_value this init ~desc : model =
 fun {path; location} astate ->
  let<*> astate, value = to_internal_value_deref path Read location init astate in
  let<+> astate, _, _ = write_value path location this ~value ~desc astate in
  astate


let emplace optional ~desc : model =
 fun {path; location} astate ->
  let<+> astate, _, _ = assign_value_fresh path location optional ~desc astate in
  astate


let value optional ~desc : model =
 fun {path; location; ret= ret_id, _} astate ->
  let<*> astate, ((value_addr, value_hist) as value) =
    to_internal_value_deref path Write location optional astate
  in
  (* Check dereference to show an error at the callsite of `value()` *)
  let<*> astate, _ = PulseOperations.eval_access path Write location value Dereference astate in
  PulseOperations.write_id ret_id (value_addr, Hist.add_call path location desc value_hist) astate
  |> Basic.ok_continue


let has_value optional ~desc : model =
 fun {path; location; ret= ret_id, _} astate ->
  let ret_addr = AbstractValue.mk_fresh () in
  let<*> astate, (value_addr, _) = to_internal_value_deref path Read location optional astate in
  let result_non_empty =
    PulseArithmetic.prune_positive value_addr astate
    >>== PulseArithmetic.prune_positive ret_addr
    >>|| PulseOperations.write_id ret_id
           (ret_addr, Hist.single_call path location ~more:"non-empty case" desc)
    >>|| ExecutionDomain.continue
  in
  let result_empty =
    PulseArithmetic.prune_eq_zero value_addr astate
    >>== PulseArithmetic.prune_eq_zero ret_addr
    >>|| PulseOperations.write_id ret_id
           (ret_addr, Hist.single_call path location ~more:"empty case" desc)
    >>|| ExecutionDomain.continue
  in
  SatUnsat.to_list result_non_empty @ SatUnsat.to_list result_empty


let get_pointer optional ~desc : model =
 fun {path; location; ret= ret_id, _} astate ->
  let<*> astate, value_addr = to_internal_value_deref path Read location optional astate in
  let value_update_hist =
    (fst value_addr, Hist.add_call path location desc ~more:"non-empty case" (snd value_addr))
  in
  let astate_value_addr =
    PulseOperations.write_id ret_id value_update_hist astate
    |> PulseArithmetic.prune_positive (fst value_addr)
    >>|| ExecutionDomain.continue
  in
  let nullptr =
    (AbstractValue.mk_fresh (), Hist.single_call path location desc ~more:"empty case")
  in
  let astate_null =
    PulseOperations.write_id ret_id nullptr astate
    |> PulseArithmetic.prune_eq_zero (fst value_addr)
    >>== PulseArithmetic.and_eq_int (fst nullptr) IntLit.zero
    >>|= PulseOperations.invalidate path
           (StackAddress (Var.of_id ret_id, snd nullptr))
           location (ConstantDereference IntLit.zero) nullptr
    >>|| ExecutionDomain.continue
  in
  SatUnsat.to_list astate_value_addr @ SatUnsat.to_list astate_null


let value_or optional default ~desc : model =
 fun {path; location; ret= ret_id, _} astate ->
  let<*> astate, value_addr = to_internal_value_deref path Read location optional astate in
  let astate_non_empty =
    let++ astate_non_empty, value =
      PulseArithmetic.prune_positive (fst value_addr) astate
      >>|= PulseOperations.eval_access path Read location value_addr Dereference
    in
    let value_update_hist =
      (fst value, Hist.add_call path location desc ~more:"non-empty case" (snd value))
    in
    PulseOperations.write_id ret_id value_update_hist astate_non_empty |> Basic.continue
  in
  let astate_default =
    let=* astate, (default_val, default_hist) =
      PulseOperations.eval_access path Read location default Dereference astate
    in
    let default_value_hist =
      (default_val, Hist.add_call path location desc ~more:"empty case" default_hist)
    in
    PulseArithmetic.prune_eq_zero (fst value_addr) astate
    >>|| PulseOperations.write_id ret_id default_value_hist
    >>|| ExecutionDomain.continue
  in
  SatUnsat.to_list astate_non_empty @ SatUnsat.to_list astate_default


let matchers : matcher list =
  let open ProcnameDispatcher.Call in
  [ -"folly" &:: "Optional" &:: "Optional" <>$ capt_arg_payload
    $+ any_arg_of_typ (-"folly" &:: "None")
    $--> assign_none ~desc:"folly::Optional::Optional(=None)"
  ; -"folly" &:: "Optional" &:: "Optional" <>$ capt_arg_payload
    $--> assign_none ~desc:"folly::Optional::Optional()"
  ; -"folly" &:: "Optional" &:: "Optional" <>$ capt_arg_payload
    $+ capt_arg_payload_of_typ (-"folly" &:: "Optional")
    $--> assign_optional_value ~desc:"folly::Optional::Optional(folly::Optional<Value> arg)"
  ; -"folly" &:: "Optional" &:: "Optional" <>$ capt_arg_payload $+ capt_arg_payload
    $+...$--> assign_value ~desc:"folly::Optional::Optional(Value arg)"
  ; -"folly" &:: "Optional" &:: "assign" <>$ capt_arg_payload
    $+ any_arg_of_typ (-"folly" &:: "None")
    $--> assign_none ~desc:"folly::Optional::assign(=None)"
  ; -"folly" &:: "Optional" &:: "assign" <>$ capt_arg_payload
    $+ capt_arg_payload_of_typ (-"folly" &:: "Optional")
    $--> assign_optional_value ~desc:"folly::Optional::assign(folly::Optional<Value> arg)"
  ; -"folly" &:: "Optional" &:: "assign" <>$ capt_arg_payload $+ capt_arg_payload
    $+...$--> assign_value ~desc:"folly::Optional::assign(Value arg)"
  ; -"folly" &:: "Optional" &:: "emplace<>" $ capt_arg_payload
    $+...$--> emplace ~desc:"folly::Optional::emplace()"
  ; -"folly" &:: "Optional" &:: "emplace" $ capt_arg_payload
    $+...$--> emplace ~desc:"folly::Optional::emplace()"
  ; -"folly" &:: "Optional" &:: "has_value" <>$ capt_arg_payload
    $+...$--> has_value ~desc:"folly::Optional::has_value()"
  ; -"folly" &:: "Optional" &:: "reset" <>$ capt_arg_payload
    $+...$--> assign_none ~desc:"folly::Optional::reset()"
  ; -"folly" &:: "Optional" &:: "value" <>$ capt_arg_payload
    $+...$--> value ~desc:"folly::Optional::value()"
  ; -"folly" &:: "Optional" &:: "operator*" <>$ capt_arg_payload
    $+...$--> value ~desc:"folly::Optional::operator*()"
  ; -"folly" &:: "Optional" &:: "operator->" <>$ capt_arg_payload
    $+...$--> value ~desc:"folly::Optional::operator->()"
  ; -"folly" &:: "Optional" &:: "get_pointer" $ capt_arg_payload
    $+...$--> get_pointer ~desc:"folly::Optional::get_pointer()"
  ; -"folly" &:: "Optional" &:: "value_or" $ capt_arg_payload $+ capt_arg_payload
    $+...$--> value_or ~desc:"folly::Optional::value_or()"
  ; -"std" &:: "optional" &:: "optional" $ capt_arg_payload
    $+ any_arg_of_typ (-"std" &:: "nullopt_t")
    $--> assign_none ~desc:"std::optional::optional(=nullopt)"
  ; -"std" &:: "optional" &:: "optional" $ capt_arg_payload
    $--> assign_none ~desc:"std::optional::optional()"
  ; -"std" &:: "optional" &:: "optional" $ capt_arg_payload
    $+ capt_arg_payload_of_typ (-"std" &:: "optional")
    $--> assign_optional_value ~desc:"std::optional::optional(std::optional<Value> arg)"
  ; -"std" &:: "optional" &:: "optional" $ capt_arg_payload $+ capt_arg_payload
    $+...$--> assign_value ~desc:"std::optional::optional(Value arg)"
  ; -"std" &:: "optional" &:: "operator=" $ capt_arg_payload
    $+ any_arg_of_typ (-"std" &:: "nullopt_t")
    $--> assign_none ~desc:"std::optional::operator=(None)"
  ; -"std" &:: "optional" &:: "operator=" $ capt_arg_payload
    $+ capt_arg_payload_of_typ (-"std" &:: "optional")
    $--> assign_optional_value ~desc:"std::optional::operator=(std::optional<Value> arg)"
  ; -"std" &:: "optional" &:: "operator=" $ capt_arg_payload $+ capt_arg_payload
    $+...$--> assign_value ~desc:"std::optional::operator=(Value arg)"
  ; -"std" &:: "optional" &:: "emplace<>" $ capt_arg_payload
    $+...$--> emplace ~desc:"std::optional::emplace()"
  ; -"std" &:: "optional" &:: "emplace" $ capt_arg_payload
    $+...$--> emplace ~desc:"std::optional::emplace()"
  ; -"std" &:: "optional" &:: "has_value" <>$ capt_arg_payload
    $+...$--> has_value ~desc:"std::optional::has_value()"
  ; -"std" &:: "__optional_storage_base" &:: "has_value" $ capt_arg_payload
    $+...$--> has_value ~desc:"std::optional::has_value()"
  ; -"std" &:: "optional" &:: "operator_bool" <>$ capt_arg_payload
    $+...$--> has_value ~desc:"std::optional::operator_bool()"
  ; -"std" &:: "optional" &:: "reset" <>$ capt_arg_payload
    $+...$--> assign_none ~desc:"std::optional::reset()"
  ; -"std" &:: "optional" &:: "value" <>$ capt_arg_payload
    $+...$--> value ~desc:"std::optional::value()"
  ; -"std" &:: "optional" &:: "operator*" <>$ capt_arg_payload
    $+...$--> value ~desc:"std::optional::operator*()"
  ; -"std" &:: "optional" &:: "operator->" <>$ capt_arg_payload
    $+...$--> value ~desc:"std::optional::operator->()"
  ; -"std" &:: "optional" &:: "value_or" $ capt_arg_payload $+ capt_arg_payload
    $+...$--> value_or ~desc:"std::optional::value_or()" ]
