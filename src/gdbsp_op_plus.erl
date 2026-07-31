%%%-------------------------------------------------------------------
%%% @doc Barrier-aware labeled sum (multi-upstream).
%%%
%%% N upstreams with N unique labels. Uses gdbsp_barrier for
%%% synchronization. Deltas come from barrier:record's Acc —
%%% no duplicate per-label buffers. Commit output is the
%%% concatenation of all flushed deltas with merged Meta.
%%%
%%% State: #{barrier => barrier_state(), downstream_label => term}
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_plus).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    barrier    := gdbsp_barrier:barrier_state(),
    n_labels   := pos_integer(),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{labels := Labels}) ->
    BS = gdbsp_barrier:init(Labels),
    {#{barrier => BS, n_labels => length(Labels), downstream_label => default},
     Labels, [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{barrier := BS, n_labels := N, downstream_label := OutLabel} = St,
             Label, Msg = {delta, _Meta, _Deltas}) ->
    case gdbsp_operator_spec:barrier_collect(St, Label, Msg, BS, N) of
        {error, Reason} ->
            {St, [{error, Reason}]};
        {not_ready, NewSt} ->
            {NewSt, []};
        {ok, NewSt, Acc} ->
            MergedMeta = merge_metas(Acc),
            case maps:get(barrier, MergedMeta, undefined) of
                state_reset ->
                    {NewSt,
                     [{send, OutLabel, {delta, MergedMeta, []}}]};
                _ ->
                    AllDeltas = lists:append(
                        [Ds || {delta, _, Ds, _} <- maps:values(Acc)]),
                    Actions = case AllDeltas of
                        [] -> [{send, OutLabel, {delta, MergedMeta, []}}];
                        _  -> [{send, OutLabel, {delta, MergedMeta, AllDeltas}}]
                    end,
                    {NewSt, Actions}
            end
    end.

-spec merge_metas(#{term() => {delta, map(), [term()], term()}}) -> map().
merge_metas(Acc) ->
    LabeledMetas = maps:map(fun(_L, {delta, M, _, _}) -> M end, Acc),
    gdbsp_operator_spec:merge_metas_consistent(LabeledMetas).
