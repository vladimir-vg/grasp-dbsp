%%%-------------------------------------------------------------------
%%% @doc Barrier-aware 1:N row expansion.
%%%
%%% Single-upstream stateless pass-through. Calls Fun(Row) which
%%% returns an array of output rows. Each element gets the input weight.
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
init(#{expr := Expr, row_type := _RowType} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    ArgName = maps:get(arg_name, Args, <<"row">>),
    KwargOrder = maps:get(kwarg_order, Args, #{}),
    Fun = fun(Row) ->
        case Value:eval_expr(Expr, Row, ArgName, KwargOrder) of
            {ok, {value, {array, _ElemType, _}, Arr}} when is_list(Arr) ->
                Arr;
            {ok, {value, {dynamic, {array, _ET, _}}, Arr}} when is_list(Arr) ->
                Arr;
            {ok, {value, {json, {array, json, _}}, Arr}} when is_list(Arr) ->
                Arr;
            _ ->
                []
        end
    end,
    {#{'fun' => Fun, downstream_label => default}, [default], [default]}.

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
