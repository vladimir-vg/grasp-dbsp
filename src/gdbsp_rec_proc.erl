%%%-------------------------------------------------------------------
%%% @doc gen_server wrapper for gdbsp_rec.
%%%
%%% Dispatches incoming delta messages by sender PID. Supports
%%% late wiring via gen_server:call: set_coordinator, set_body_inputs,
%%% set_body_output, set_source, set_consumer. Unknown sender → exit.
%%%
%%% body_input_pids — where Rec forwards its diffs (body entry points).
%%% body_output_pid — which PID sends feedback back to Rec (body exit).
%%%
%%% Passes self() as RecPid to all pure handlers.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec_proc).
-behaviour(gen_server).

-include("gdbsp_debug.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(InitArgs) ->
    gen_server:start_link(?MODULE, InitArgs, []).

init(InitArgs) ->
    State = gdbsp_rec:init_state(InitArgs),
    {ok, State}.

%%====================================================================
%% gen_server calls — late wiring
%%====================================================================

handle_call({set_coordinator, Pid}, _From, State) ->
    {reply, ok, State#{coordinator := Pid}};
handle_call({set_body_inputs, Pids}, _From, State) ->
    #{name := Name, body_output_pid := BOP} = State,
    _ = case BOP of
        OutPid when OutPid =/= undefined ->
            case lists:member(OutPid, Pids) of
                true -> exit({self_loop_body_entry, Name, OutPid});
                false -> ok
            end;
        _ -> ok
    end,
    {reply, ok, State#{body_input_pids := Pids}};
handle_call({set_body_output, Pid}, _From, State) ->
    #{name := Name, body_input_pids := BIP} = State,
    case lists:member(Pid, BIP) of
        true -> exit({self_loop_body_entry, Name, Pid});
        false -> ok
    end,
    {reply, ok, State#{body_output_pid := Pid}};
handle_call({set_source, Pid}, _From, State) ->
    {reply, ok, State#{source_pid := Pid}};
handle_call({add_extra_source, Pid}, _From, #{extra_source_pids := Extra} = State) ->
    {reply, ok, State#{extra_source_pids := [Pid | Extra]}};
handle_call(get_coordinator, _From, #{coordinator := Coord} = State) ->
    {reply, {ok, Coord}, State};
handle_call({set_consumer, Pid}, _From, State) ->
    {reply, ok, State#{consumers := [Pid]}};
handle_call({add_consumer, Pid}, _From, #{consumers := Cs} = State) ->
    {reply, ok, State#{consumers := [Pid | Cs]}};
handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

%%====================================================================
%% handle_info — delta dispatch
%%====================================================================

handle_info({delta, _Meta, _Deltas, From} = Msg, State) ->
    {noreply, dispatch_delta(From, Msg, State)};
handle_info({reset, Ref, ReplyTo}, State) ->
    State2 = gdbsp_rec:reset_state(State),
    ReplyTo ! {reset_ack, Ref},
    {noreply, State2};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal — delta dispatch
%%====================================================================

dispatch_delta(From, Msg, State) ->
    #{name := Name, coordinator := Coord, body_output_pid := BodyOut} = State,
    Source = maps:get(source_pid, State, undefined),
    ExtraSources = maps:get(extra_source_pids, State, []),
    Self = self(),
    {State2, Actions} = case From of
        Coord when Coord =/= undefined ->
            gdbsp_rec:handle_coord(State, Msg, Self);
        BodyOut when BodyOut =/= undefined ->
            gdbsp_rec:handle_body(State, Msg, Self);
        Source when Source =/= undefined ->
            gdbsp_rec:handle_source(State, Msg, Self);
        _ ->
            case lists:member(From, ExtraSources) of
                true ->
                    gdbsp_rec:handle_source(State, Msg, Self);
                false ->
                    exit({unknown_sender, From})
            end
    end,
    maybe_self_loop(State2, Actions, Self),
    run_actions(Actions),
    State2.

maybe_self_loop(#{body_output_pid := BodyOut, body_input_pids := BodyEntryPids,
                    name := Name},
                Actions, RecPid) ->
    case BodyOut =:= RecPid of
        false -> ok;
        true ->
            HasBarrier = lists:any(
                fun({send, P, {delta, Meta, _, _}}) ->
                    maps:is_key(barrier, Meta) andalso lists:member(P, BodyEntryPids);
                   (_) -> false
                end, Actions),
            case HasBarrier of
                false -> ok;
                true ->
                    {delta, Meta, _Deltas, _From} = find_barrier_delta(Actions, BodyEntryPids),
                    ?DBG("REC ~s SELF_LOOP: injecting self-message with barrier=~p",
                           [Name, maps:get(barrier, Meta, undefined)]),
                    RecPid ! {delta, Meta, [], RecPid}
            end
    end.

find_barrier_delta([{send, P, {delta, Meta, _, _} = Msg} | Rest], BodyEntryPids) ->
    case maps:is_key(barrier, Meta) andalso lists:member(P, BodyEntryPids) of
        true -> Msg;
        false -> find_barrier_delta(Rest, BodyEntryPids)
    end;
find_barrier_delta([_ | Rest], BodyEntryPids) ->
    find_barrier_delta(Rest, BodyEntryPids).

%%====================================================================
%% Internal — action execution
%%====================================================================

run_actions([]) -> ok;
run_actions([{exit, Reason} | _Rest]) ->
    exit(Reason);
run_actions([{send, Pid, Msg} | Rest]) ->
    Pid ! Msg,
    run_actions(Rest);
run_actions([{report_coord, Pid, Term} | Rest]) ->
    Pid ! Term,
    run_actions(Rest).
