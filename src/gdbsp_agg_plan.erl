%%%-------------------------------------------------------------------
%%% @doc Aggregate function body → plan compilation.
%%%
%%% Compiles an `aggregate_function` typespec + `:= function(...)` body
%%% into a self-contained plan term consumed unchanged by the runtime
%%% aggregate operator. Enforces the structural rules for aggregate
%%% bodies (§3 of the aggregate-udf implementation plan).
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_agg_plan).

-include("gdbsp_parse.hrl").
-include("gdbsp_expr.hrl").
-include("gdbsp_type.hrl").

-export([compile/3]).

-type slot() :: #{
    name        => binary(),
    impl        => {{module(), atom(), 2}, {module(), atom(), 3}, {module(), atom(), 1}},
    arg         => expr() | none,
    result_type => gdbsp_column_type()
}.
-type plan() :: #{
    slots        => [slot()],
    result_expr  => expr(),
    result_type  => gdbsp_column_type(),
    row_arg      => binary(),
    kwarg_order  => #{binary() => [binary()]}
}.

-export_type([plan/0, slot/0]).

-spec compile(#gdbsp_fn_def{}, #gdbsp_typespec{}, gdbsp_builtins:stdlib_map()) ->
    {ok, plan()} | {error, [term()]}.
compile(FnDef, TS, StdlibMap) ->
    #gdbsp_typespec{spec = {aggregate_function, PosTypes, KwMap, RetType}} = TS,
    #gdbsp_fn_def{params = Params} = FnDef,
    case is_struct_type(RetType) of
        false ->
            {error, [type_conflict]};
        true ->
            AggNames = gdbsp_builtins:aggregate_function_names(StdlibMap),
            try
                Body = gdbsp_compile_expr:lower_agg_body(FnDef, TS, AggNames),
                TypeEnv = gdbsp_compile_expr:build_type_env(Params, PosTypes, KwMap),
                build_plan(Body, TypeEnv, RetType, Params, StdlibMap)
            catch
                throw:{lower_error, _Line, Reason} ->
                    {error, [Reason]}
            end
    end.

is_struct_type({struct, _, _}) -> true;
is_struct_type(_) -> false.

build_plan(Body, TypeEnv, RetType, Params, StdlibMap) ->
    RowArg = row_arg_name(Params),
    case collect_slots(Body, RowArg, TypeEnv, StdlibMap) of
        {ok, ResultExpr, Slots} ->
            KwargOrder = gdbsp_builtins:build_kwarg_order(StdlibMap),
            {ok, #{slots => Slots,
                   result_expr => ResultExpr,
                   result_type => RetType,
                   row_arg => RowArg,
                   kwarg_order => KwargOrder}};
        {error, _} = E -> E
    end.

row_arg_name([{pos, Name} | _]) -> Name;
row_arg_name(_) -> <<"row">>.

%%====================================================================
%% Slot collection — walks the lowered body, extracts aggregate calls
%% into slots (left-to-right), and rewrites each into a {slot, N}
%% placeholder. Enforces:
%%   - ≥1 aggregate call        → no_aggregate_call
%%   - no nesting               → nested_aggregate_call
%%   - row param only in agg arg → row_ref_outside_aggregate
%%====================================================================

collect_slots(Expr, RowArg, TypeEnv, StdlibMap) ->
    case has_agg(Expr) of
        false ->
            {error, [no_aggregate_call]};
        true ->
            case collect(Expr, top, RowArg, TypeEnv, StdlibMap, [], 0) of
                {ok, NewExpr, RevSlots, _Idx} -> {ok, NewExpr, lists:reverse(RevSlots)};
                {error, _} = E -> E
            end
    end.

%% True iff the lowered body contains any {agg, ...} node. Since a nested agg
%% always sits inside an outer agg's argument, presence of any agg node implies
%% at least one top-level aggregate call.
has_agg({agg, _, _, _}) -> true;
has_agg({value, _, _}) -> false;
has_agg({arg, _}) -> false;
has_agg({call, _, PosArgs, KwArgs}) ->
    lists:any(fun has_agg/1, PosArgs) orelse
    lists:any(fun({_, V}) -> has_agg(V) end, maps:to_list(KwArgs));
has_agg({get, Obj, Keys}) ->
    has_agg(Obj) orelse lists:any(fun has_agg/1, Keys);
has_agg({slice, Obj, S1, S2, S3}) ->
    has_agg(Obj) orelse
    (S1 =/= undefined andalso has_agg(S1)) orelse
    (S2 =/= undefined andalso has_agg(S2)) orelse
    (S3 =/= undefined andalso has_agg(S3)).

collect({agg, Name, PosArgs, KwArgs}, top, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    ArgExpr = case PosArgs of
        [] -> none;
        [A] -> A;
        _ -> throw({bad_agg_arity, Name})
    end,
    ArgResult = case ArgExpr of
        none -> {ok, none, [], 0};
        _ -> collect(ArgExpr, in_arg, RowArg, TypeEnv, StdlibMap, [], 0)
    end,
    case ArgResult of
        {ok, ArgExpr2, _SubSlots, _} ->
            case infer_slot_type(Name, PosArgs, KwArgs, TypeEnv, StdlibMap) of
                {ok, SlotT} ->
                    Slot = #{name => Name,
                             impl => agg_impl(Name),
                             arg => ArgExpr2,
                             result_type => SlotT},
                    {ok, {value, SlotT, {slot, Idx}}, [Slot | Slots], Idx + 1};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
collect({agg, _Name, _PosArgs, _KwArgs}, in_arg, _RowArg, _TypeEnv, _StdlibMap, _Slots, _Idx) ->
    {error, [nested_aggregate_call]};
collect({arg, Name}, top, RowArg, _TypeEnv, _StdlibMap, _Slots, _Idx) when Name =:= RowArg ->
    {error, [row_ref_outside_aggregate]};
collect({arg, _Name}, _Mode, _RowArg, _TypeEnv, _StdlibMap, Slots, Idx) ->
    {ok, {arg, _Name}, Slots, Idx};
collect({value, _, _} = V, _Mode, _RowArg, _TypeEnv, _StdlibMap, Slots, Idx) ->
    {ok, V, Slots, Idx};
collect({call, Name, PosArgs, KwArgs}, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    case collect_list(PosArgs, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) of
        {ok, PosArgs2, Slots1, Idx1} ->
            case collect_kwmap(KwArgs, Mode, RowArg, TypeEnv, StdlibMap, Slots1, Idx1) of
                {ok, KwArgs2, Slots2, Idx2} ->
                    {ok, {call, Name, PosArgs2, KwArgs2}, Slots2, Idx2};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
collect({get, Obj, Keys}, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    case collect(Obj, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) of
        {ok, Obj2, Slots1, Idx1} ->
            case collect_list(Keys, Mode, RowArg, TypeEnv, StdlibMap, Slots1, Idx1) of
                {ok, Keys2, Slots2, Idx2} ->
                    {ok, {get, Obj2, Keys2}, Slots2, Idx2};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
collect({slice, Obj, Start, Stop, Step}, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    case collect(Obj, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) of
        {ok, Obj2, Slots1, Idx1} ->
            case collect_opt(Start, Mode, RowArg, TypeEnv, StdlibMap, Slots1, Idx1) of
                {ok, Start2, Slots2, Idx2} ->
                    case collect_opt(Stop, Mode, RowArg, TypeEnv, StdlibMap, Slots2, Idx2) of
                        {ok, Stop2, Slots3, Idx3} ->
                            case collect_opt(Step, Mode, RowArg, TypeEnv, StdlibMap, Slots3, Idx3) of
                                {ok, Step2, Slots4, Idx4} ->
                                    {ok, {slice, Obj2, Start2, Stop2, Step2}, Slots4, Idx4};
                                {error, _} = E -> E
                            end;
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

collect_list([], _Mode, _RowArg, _TypeEnv, _StdlibMap, Slots, Idx) ->
    {ok, [], Slots, Idx};
collect_list([E | Rest], Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    case collect(E, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) of
        {ok, E2, Slots1, Idx1} ->
            case collect_list(Rest, Mode, RowArg, TypeEnv, StdlibMap, Slots1, Idx1) of
                {ok, Rest2, Slots2, Idx2} -> {ok, [E2 | Rest2], Slots2, Idx2};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

collect_kwmap(KwMap, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    collect_kwlist(maps:to_list(KwMap), Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx, []).

collect_kwlist([], _Mode, _RowArg, _TypeEnv, _StdlibMap, Slots, Idx, Acc) ->
    {ok, maps:from_list(Acc), Slots, Idx};
collect_kwlist([{K, V} | Rest], Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx, Acc) ->
    case collect(V, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) of
        {ok, V2, Slots1, Idx1} ->
            collect_kwlist(Rest, Mode, RowArg, TypeEnv, StdlibMap, Slots1, Idx1, [{K, V2} | Acc]);
        {error, _} = Err -> Err
    end.

collect_opt(undefined, _Mode, _RowArg, _TypeEnv, _StdlibMap, Slots, Idx) ->
    {ok, undefined, Slots, Idx};
collect_opt(E, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx) ->
    collect(E, Mode, RowArg, TypeEnv, StdlibMap, Slots, Idx).

infer_slot_type(Name, PosArgs, KwArgs, TypeEnv, StdlibMap) ->
    gdbsp_type_infer_expr:infer_expr({agg, Name, PosArgs, KwArgs}, TypeEnv, StdlibMap).

agg_impl(Name) ->
    {ok, Triple} = gdbsp_builtins:agg_impl(Name),
    Triple.
