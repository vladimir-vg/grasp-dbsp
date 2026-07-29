%%%-------------------------------------------------------------------
%%% @doc Generic gen_server wrapper for gdbsp_op_* behavior modules.
%%%
%%% Maintains a PID→Label map (filled by wiring_update). On each
%%% incoming {delta, Meta, Deltas, From}, resolves Label and calls
%%% Module:handle_delta(OpState, Label, {delta, Meta, Deltas}).
%%%
%%% Two wiring_update variants:
%%%   {wiring_update, Up, Down}           — initial wiring (no FromEpoch).
%%%     Applied immediately ONLY if epoch is undefined. Crashes otherwise.
%%%   {wiring_update, Up, Down, FromEpoch} — deferred wiring. Always stored
%%%     in pending_wiring and applied when the epoch reaches FromEpoch.
%%%
%%% Operators emit label-based actions ({send, Label, Msg}). The proc
%%% resolves labels to PIDs via downstream_map.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_proc).
-behaviour(gen_server).

-include("gdbsp_debug.hrl").

-export([start_link/2, start_link/3, start_link/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Custom-message handler seam: an optional fun((Msg, OpState) ->
%% {OpState, Actions}) dispatched from the catch-all handle_info for messages
%% the proc does not otherwise handle (e.g. checkpoint / restore). gg-basic
%% registers none (default undefined); gg-runtime registers one for
%% checkpointing. Actions reuse the operator action protocol
%% ({send, _, _} / {error, _}) executed by execute_actions/2.
-type msg_handler() :: undefined | fun((term(), term()) -> {term(), [term()]}).

-spec start_link(module(), map()) -> {ok, pid()} | {error, term()}.
start_link(Mod, InitArgs) ->
    start_link(Mod, InitArgs, undefined, undefined).

-spec start_link(module(), map(), map()) -> {ok, pid()} | {error, term()}.
start_link(Mod, InitArgs, PreloadedState) ->
    start_link(Mod, InitArgs, PreloadedState, undefined).

%% PreloadedState =:= undefined -> fresh init via Mod:init/1; otherwise
%% restore-on-spawn from PreloadedState. MsgHandler defaults to undefined.
-spec start_link(module(), map(), map() | undefined, msg_handler()) ->
    {ok, pid()} | {error, term()}.
start_link(Mod, InitArgs, PreloadedState, MsgHandler) ->
    gen_server:start_link(?MODULE, {Mod, InitArgs, PreloadedState, MsgHandler}, []).

init({Mod, InitArgs, undefined, MsgHandler}) ->
    {OpState, _InLabels, _OutLabels} = Mod:init(InitArgs),
    {ok, base_state(Mod, InitArgs, OpState, MsgHandler)};
init({Mod, InitArgs, PreloadedState, MsgHandler}) ->
    {ok, base_state(Mod, InitArgs, PreloadedState, MsgHandler)}.

base_state(Mod, InitArgs, OpState, MsgHandler) ->
    #{
        mod             => Mod,
        init_args       => InitArgs,
        op_state        => OpState,
        pidmap          => #{},
        downstream_map  => #{},
        current_epoch   => undefined,
        pending_wiring  => #{},
        msg_handler     => MsgHandler
    }.

%%====================================================================
%% handle_info
%%====================================================================

handle_info({wiring_update, Upstream, Downstream},
            #{current_epoch := CurE} = State) ->
    case CurE of
        undefined ->
            {noreply, apply_wiring(Upstream, Downstream, State)};
        _ ->
            exit({wiring_after_epoch_started})
    end;
handle_info({wiring_update, Upstream, Downstream, FromEpoch},
            #{current_epoch := CurE} = State) ->
    case CurE of
        _ when FromEpoch =< CurE ->
            {noreply, apply_wiring(Upstream, Downstream, State)};
        _ ->
            PW = maps:get(pending_wiring, State),
            {noreply, State#{pending_wiring := PW#{FromEpoch => {Upstream, Downstream}}}}
    end;
handle_info({delta, Meta, Deltas, From},
             State) ->
    #{epoch := E} = Meta,
    State1 = advance_epoch(E, State),
    #{pidmap := PM1, op_state := St2, mod := Mod} = State1,
    Label = maps:get(From, PM1),
    Barrier = maps:get(barrier, Meta, undefined),
    ?DBG("OP ~p pid=~p IN: barrier=~p deltas=~w label=~p from=~w",
           [Mod, self(), Barrier, length(Deltas), Label, From]),
    case Barrier of
        epoch_done ->
            ?DBG("OP ~p pid=~p BUG4_TRACE: received epoch_done from ~p (label=~p)",
                   [Mod, self(), From, Label]);
        _ -> ok
    end,
    {St3, Actions} = Mod:handle_delta(St2, Label, {delta, Meta, Deltas}),
    ActionCount = length(Actions),
    case ActionCount of
        0 -> ok;
        _ -> ?DBG("OP ~p OUT: barrier=~p actions=~w",
                    [Mod, Barrier, ActionCount])
    end,
    execute_actions(Actions, State1),
    {noreply, State1#{op_state := St3}};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info({reset, Ref, ReplyTo},
            #{mod := Mod, init_args := InitArgs,
              downstream_map := DsMap} = State) ->
    {OpState, _InLabels, _OutLabels} = Mod:init(InitArgs),
    State1 = State#{op_state := OpState,
                    current_epoch := undefined,
                    pending_wiring := #{}},
    %% Re-derive the op_state downstream fields from the preserved wiring.
    State2 = apply_wiring(maps:get(pidmap, State1), DsMap, State1),
    ReplyTo ! {reset_ack, Ref},
    {noreply, State2};
handle_info(Msg, #{msg_handler := Handler, op_state := OpSt} = State)
  when is_function(Handler, 2) ->
    {NewOpSt, Actions} = Handler(Msg, OpSt),
    execute_actions(Actions, State),
    {noreply, State#{op_state := NewOpSt}};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% handle_call / handle_cast
%%====================================================================

handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

%%====================================================================
%% Internal — wiring
%%====================================================================

apply_wiring(Upstream, Downstream,
             #{op_state := St} = State) ->
    DsMap = Downstream,
    St2 = case maps:to_list(Downstream) of
        [{Label, [Pid | _]} | _] ->
            St#{downstream => Pid, downstream_label => Label};
        [{Label, Pid} | _] when not is_list(Pid) ->
            St#{downstream => Pid, downstream_label => Label};
        [] ->
            St#{downstream => undefined}
    end,
    State#{pidmap := Upstream, downstream_map := DsMap, op_state := St2}.

%%====================================================================
%% Internal — epoch advance + pending wiring
%%====================================================================

advance_epoch(E, #{current_epoch := CurE} = State)
  when CurE =:= undefined; E > CurE ->
    State1 = State#{current_epoch := E},
    PW = maps:get(pending_wiring, State1),
    {ToApply, Remaining} =
        lists:partition(fun({FE, _}) -> FE =< E end, maps:to_list(PW)),
    lists:foldl(
        fun({_FE, {Up, Ds}}, Acc) ->
            apply_wiring(Up, Ds, Acc)
        end,
        State1#{pending_wiring := maps:from_list(Remaining)},
        ToApply
    );
advance_epoch(_E, State) ->
    State.

%%====================================================================
%% Internal — action execution
%%====================================================================

execute_actions([], _State) -> ok;
execute_actions([{send, Label, {delta, Meta, Deltas}} | Rest],
                State) ->
    DsMap = maps:get(downstream_map, State),
    Pids = normalize_pid_list(maps:get(Label, DsMap, [])),
    ?DBG("OP ~p pid=~p SEND: dests=~p deltas=~w label=~p",
           [maps:get(mod, State), self(), Pids, length(Deltas), Label]),
    lists:foreach(fun(Pid) -> Pid ! {delta, Meta, Deltas, self()} end, Pids),
    execute_actions(Rest, State);
execute_actions([{send, Label, Msg} | Rest], State) ->
    DsMap = maps:get(downstream_map, State),
    Pids = normalize_pid_list(maps:get(Label, DsMap, [])),
    lists:foreach(fun(Pid) -> Pid ! Msg end, Pids),
    execute_actions(Rest, State);
execute_actions([{error, Reason} | _], _State) ->
    exit(Reason).

normalize_pid_list(L) when is_list(L) -> L;
normalize_pid_list(Pid) when is_pid(Pid) -> [Pid].
