%%%-------------------------------------------------------------------
%%% @doc Thin runtime orchestration: compiles a program and wires a
%%% running circuit (operators + input nodes + output sinks + ingress),
%%% then drives epochs.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_runtime).

-export([start/1, stop/1]).
-export([feed/3, mark_exhausted/2, step/1, await_epoch/2]).
-export([source_types/1, output_types/1, header/2, lines/3]).

-type runtime() :: map().

%% @doc Instantiate a running circuit from a gdbsp_loader:compile/3 result.
-spec start(map()) -> {ok, runtime()} | {error, term()}.
start(#{plan := Plan, source_types := SourceTypes, output_types := OutputTypes}) ->
    InputNodes = maps:map(
        fun(_Table, _Src) ->
            {ok, Pid} = gdbsp_input_node:start_link(),
            Pid
        end, SourceTypes),
    Sinks = maps:map(
        fun(_Name, Type) ->
            {ok, Pid} = gdbsp_output_sink:start_link(Type),
            Pid
        end, OutputTypes),
    {ok, Circuit} = gdbsp_circuit_proc:start_link(),
    ok = gen_server:call(Circuit, {circuit_update, Plan, InputNodes, Sinks}),
    {ok, Ingress} = gdbsp_ingress:start_link(InputNodes),
    {ok, #{circuit => Circuit, input_nodes => InputNodes, sinks => Sinks,
           ingress => Ingress, source_types => SourceTypes,
           output_types => OutputTypes}}.

-spec stop(runtime()) -> ok.
stop(Rt) ->
    catch gen_server:call(maps:get(circuit, Rt), stop),
    maps:foreach(fun(_, P) -> catch gdbsp_output_sink:stop(P) end,
                 maps:get(sinks, Rt, #{})),
    maps:foreach(fun(_, P) -> catch gdbsp_input_node:stop(P) end,
                 maps:get(input_nodes, Rt, #{})),
    ok.

-spec feed(runtime(), binary(), [{integer(), term()}]) -> ok.
feed(Rt, Table, Rows) ->
    gdbsp_ingress:feed(maps:get(ingress, Rt), Table, Rows).

-spec mark_exhausted(runtime(), binary()) -> ok.
mark_exhausted(Rt, Table) ->
    gdbsp_ingress:mark_exhausted(maps:get(ingress, Rt), Table).

-spec step(runtime()) -> {ok, non_neg_integer()} | exhausted | idle.
step(Rt) ->
    gdbsp_ingress:step(maps:get(ingress, Rt)).

%% @doc Block until every output sink has committed the given epoch.
-spec await_epoch(runtime(), non_neg_integer()) -> ok.
await_epoch(Rt, Epoch) ->
    maps:foreach(
        fun(_, Sink) ->
            ok = gdbsp_output_sink:await_epoch_done(Sink, Epoch, 30000)
        end, maps:get(sinks, Rt)).

-spec source_types(runtime()) -> #{binary() => {binary(), term()}}.
source_types(Rt) -> maps:get(source_types, Rt).

-spec output_types(runtime()) -> #{binary() => term()}.
output_types(Rt) -> maps:get(output_types, Rt).

-spec header(runtime(), binary()) -> map().
header(Rt, Name) ->
    gdbsp_output_sink:get_header(maps:get(Name, maps:get(sinks, Rt))).

-spec lines(runtime(), binary(), non_neg_integer()) -> [[term()]].
lines(Rt, Name, Epoch) ->
    gdbsp_output_sink:get_lines_by_epoch(
        maps:get(Name, maps:get(sinks, Rt)), Epoch).
