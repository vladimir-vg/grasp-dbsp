%%%-------------------------------------------------------------------
%%% @doc Barrier-aware 1:N row expansion.
%%%
%%% Single-upstream stateless pass-through. Calls Fun(Row) which
%%% returns a list of output rows. Each gets the input weight.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_flat_map).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    'fun'      := fun((term()) -> [term()]),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{expr := Expr, row_type := _RowType, unnest_outs := OutVars} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    ArgName = maps:get(arg_name, Args, <<"row">>),
    Fun = fun(Row) ->
        case Value:eval_expr(Expr, Row, ArgName) of
            {ok, {value, {array, ElemType, _}, Arr}} ->
                unnest_array(Arr, ElemType, OutVars, Row, Value);
            {ok, {value, {map, _KType, VType}, MapVals}} ->
                unnest_map(MapVals, VType, OutVars, Row, Value);
            {ok, {value, {struct, _, _}, TypedVals}} ->
                unnest_struct_value(TypedVals, OutVars, Row, Value);
            {ok, {value, {json, {array, json, _}}, Arr}} when is_list(Arr) ->
                unnest_array(Arr, json, OutVars, Row, Value);
            {ok, {value, {json, {map, string, json}}, MapVals}} when is_map(MapVals) ->
                unnest_map(MapVals, json, OutVars, Row, Value);
            {ok, {value, {optional, json},
                  {value, {value, {json, {array, json, _}}, Arr}}}} when is_list(Arr) ->
                unnest_array(Arr, json, OutVars, Row, Value);
            {ok, {value, {optional, json},
                  {value, {value, {json, {map, string, json}}, MapVals}}}} when is_map(MapVals) ->
                unnest_map(MapVals, json, OutVars, Row, Value);
            {ok, {value, {dynamic, {array, ET, _}}, Arr}} when is_list(Arr) ->
                unnest_array(Arr, ET, OutVars, Row, Value);
            {ok, {value, {dynamic, {map, _KT, VT}}, MapVals}} when is_map(MapVals) ->
                unnest_map(MapVals, VT, OutVars, Row, Value);
            _ ->
                []
        end
    end,
    {#{'fun' => Fun, downstream_label => default}, [default], [default]}.

unnest_array(Arr, ElemType, [V], Row, Value) ->
    [Value:struct_extend(Row, V, maybe_wrap(Item, ElemType)) || Item <- Arr];
unnest_array(Arr, ElemType, [I, V], Row, Value) ->
    Indexed = lists:zip(lists:seq(0, length(Arr) - 1), Arr),
    [begin R1 = Value:struct_extend(Row, I, {value, i64, Idx}),
           Value:struct_extend(R1, V, maybe_wrap(Val, ElemType)) end
     || {Idx, Val} <- Indexed].

unnest_map(MapVals, ValType, [K, V], Row, Value) ->
    [begin R1 = Value:struct_extend(Row, K, {value, string, DK}),
           Value:struct_extend(R1, V, maybe_wrap(DV, ValType)) end
     || {DK, DV} <- maps:to_list(MapVals)].

unnest_struct_value(TypedVals, [K, V], Row, Value) ->
    [begin R1 = Value:struct_extend(Row, K, {value, string, DK}),
           Value:struct_extend(R1, V, DV) end
     || {DK, DV} <- maps:to_list(TypedVals)].

maybe_wrap({value, _, _} = V, _ElemType) -> V;
maybe_wrap(Raw, ElemType) -> {value, ElemType, Raw}.

-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{'fun' := Fun, downstream_label := Label} = St, default,
             {delta, Meta, Deltas}) ->
    Expanded = [{W, R} || {W, Row} <- Deltas,
                         Rs <- [try Fun(Row) catch throw:drop_row -> [] end],
                         R <- Rs],
    {St, gdbsp_operator_spec:maybe_emit(Label, Meta, Expanded)}.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
