%%%-------------------------------------------------------------------
%%% @doc Barrier-aware weight negation.
%%%
%%% Single-upstream stateless pass-through. Flips the sign of every
%%% weight — preserves rows and Meta.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_neg).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(_Args) ->
    {#{downstream_label => default}, [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{downstream_label := Label} = St, default,
             {delta, Meta, Deltas}) ->
    Negated = [{-W, Row} || {W, Row} <- Deltas],
    {St, gdbsp_operator_spec:maybe_emit(Label, Meta, Negated)}.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
