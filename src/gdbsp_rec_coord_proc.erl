%%%-------------------------------------------------------------------
%%% @doc Process wrapper for gdbsp_rec_coord.
%%%
%%% gen_server that dispatches streaming_started, source_done, and
%%% iter_result messages to the pure state machine. Supports late
%%% registration via gen_server:call set_rec (only while epoch is
%%% undefined — i.e., before computation has started).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec_coord_proc).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init(Args) ->
    {State, _Actions} = gdbsp_rec_coord:init(Args),
    {ok, State}.

handle_call({set_rec, Pid, Name, Role}, _From,
            #{epoch := Epoch} = State) when Role =:= sourced;
                                            Role =:= sourceless ->
    case Epoch of
        undefined ->
            Key = Role,
            Old = maps:get(Key, State),
            {reply, ok, State#{Key := Old#{Pid => Name}}};
        _ ->
            {reply, {error, epoch_already_started}, State}
    end;
handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({activate}, State) ->
    {State2, Actions} = gdbsp_rec_coord:begin_epoch(State),
    execute_actions(Actions),
    {noreply, State2};
handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({streaming_started, E, From}, State) ->
    {State2, Actions} = gdbsp_rec_coord:handle_streaming_started(
        State, From, E),
    execute_actions(Actions),
    {noreply, State2};
handle_info({source_done, E, HasNeg, From}, State) ->
    {State2, Actions} = gdbsp_rec_coord:handle_source_done(State, From, E, HasNeg),
    execute_actions(Actions),
    {noreply, State2};
handle_info({iter_result, E, N, Result, From}, State) ->
    {State2, Actions} = gdbsp_rec_coord:handle_iter_result(
        State, From, E, N, Result),
    execute_actions(Actions),
    {noreply, State2};
handle_info({reset, Ref, ReplyTo}, State) ->
    State2 = gdbsp_rec_coord:reset_state(State),
    ReplyTo ! {reset_ack, Ref},
    {noreply, State2};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

execute_actions([]) -> ok;
execute_actions([{send, Pid, Msg} | Rest]) ->
    Pid ! Msg,
    execute_actions(Rest);
execute_actions([{exit, Reason} | _Rest]) ->
    exit(Reason).
