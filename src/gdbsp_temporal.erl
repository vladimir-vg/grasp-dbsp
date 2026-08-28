%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — temporal (interval) operations.
%%%
%%% Interval values are `{Months, Days, Microseconds}` triples,
%%% with `Months` and `Days` stored as `i32` and `Microseconds` as `i64`
%%% (matching PostgreSQL `interval`; Erlang integers are arbitrary
%%% precision, so the width is a spec-level note).
%%% Arithmetic is component-wise with no cross-unit normalization
%%% (see docs/plans/function-semantics-robustness-plan.md §9).
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_temporal).

-include("gdbsp_type.hrl").

-export([temporal_add_interval_interval/2, temporal_sub_interval_interval/2]).

%%====================================================================
%% Interval arithmetic (component-wise, no normalization)
%%====================================================================

temporal_add_interval_interval({value, interval, {M1, D1, U1}},
                               {value, interval, {M2, D2, U2}}) ->
    {value, interval, {M1 + M2, D1 + D2, U1 + U2}}.

temporal_sub_interval_interval({value, interval, {M1, D1, U1}},
                               {value, interval, {M2, D2, U2}}) ->
    {value, interval, {M1 - M2, D1 - D2, U1 - U2}}.
