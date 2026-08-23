%%%-------------------------------------------------------------------
%%% @doc Barrier-aware predicate filter.
%%%
%%% Single-upstream stateless pass-through. Keeps only rows where
%%% Pred(Row) returns true. Preserves weights and Meta.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_filter).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    pred      := fun((term()) -> boolean()),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{expr := Expr, row_type := _RowType} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    ArgName = maps:get(arg_name, Args, <<"row">>),
    Pred = fun(Row) ->
        case Value:eval_expr(Expr, Row, ArgName) of
            {ok, {value, {enum, [<<"false">>, <<"true">>]}, true}} -> true;
            _ -> false
        end
    end,
    {#{pred => Pred, downstream_label => default}, [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{pred := Pred, downstream_label := Label} = St, default,
             {delta, Meta, Deltas}) ->
    Filtered = [{W, Row} || {W, Row} <- Deltas,
                             try Pred(Row) catch throw:drop_row -> false end],
    {St, gdbsp_operator_spec:maybe_emit(Label, Meta, Filtered)}.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
