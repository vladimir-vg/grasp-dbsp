%%%-------------------------------------------------------------------
%%% @doc Output sink — the terminal endpoint for a named output stream.
%%%
%%% Wired into the circuit as an output consumer (same {delta, Meta,
%%% Deltas, From} / {wiring_update, ...} protocol as the operators).
%%% Emits a JSONL header line (once) followed by one data line per
%%% delta. Retains raw deltas per epoch for pull-based consumers and
%%% broadcasts encoded lines to push-based subscribers.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_output_sink).
-behaviour(gen_server).

-export([start_link/1]).
-export([pid/1, stop/1]).
-export([subscribe/2, unsubscribe/2]).
-export([get_header/1, get_by_epoch/2, get_lines_by_epoch/2]).
-export([await_epoch_done/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%%====================================================================
%% API
%%====================================================================

-spec start_link(term()) -> {ok, pid()} | {error, term()}.
start_link(OutputType) ->
    gen_server:start_link(?MODULE, OutputType, []).

-spec pid(pid()) -> pid().
pid(Pid) -> Pid.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%% @doc Register a push subscriber. The subscriber receives
%% {output_header, Header}, then {output_line, Line} per delta, then
%% {output_epoch_done, Epoch} per committed epoch.
-spec subscribe(pid(), pid()) -> ok.
subscribe(Pid, Subscriber) ->
    gen_server:call(Pid, {subscribe, Subscriber}).

-spec unsubscribe(pid(), pid()) -> ok.
unsubscribe(Pid, Subscriber) ->
    gen_server:call(Pid, {unsubscribe, Subscriber}).

-spec get_header(pid()) -> map().
get_header(Pid) ->
    gen_server:call(Pid, get_header).

%% @doc Raw deltas ({Weight, Row}) retained for an epoch (pull mode).
-spec get_by_epoch(pid(), non_neg_integer()) -> [{integer(), term()}].
get_by_epoch(Pid, Epoch) ->
    gen_server:call(Pid, {get_by_epoch, Epoch}).

%% @doc Encoded JSONL lines ([Weight, RowJson]) for an epoch.
-spec get_lines_by_epoch(pid(), non_neg_integer()) -> [[term()]].
get_lines_by_epoch(Pid, Epoch) ->
    gen_server:call(Pid, {get_lines_by_epoch, Epoch}).

%% @doc Block until the epoch_done barrier for the given epoch has been
%% received. Returns ok, or exits on timeout.
-spec await_epoch_done(pid(), non_neg_integer(), timeout()) -> ok.
await_epoch_done(Pid, Epoch, Timeout) ->
    Ref = make_ref(),
    Pid ! {await_epoch_done, Epoch, self(), Ref},
    receive
        {epoch_done, Ref} -> ok
    after Timeout ->
        error({await_epoch_done_timeout, {epoch, Epoch}})
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(OutputType) ->
    {ok, #{
        type => OutputType,
        header => gdbsp_value_json:columns_to_json(OutputType),
        by_epoch => #{},
        lines_by_epoch => #{},
        subscribers => [],
        done_epochs => [],
        waiters => #{}
    }}.

handle_call({subscribe, Sub}, _From, #{subscribers := Subs} = State) ->
    Header = maps:get(header, State),
    Sub ! {output_header, Header},
    {reply, ok, State#{subscribers := [Sub | Subs]}};
handle_call({unsubscribe, Sub}, _From, #{subscribers := Subs} = State) ->
    {reply, ok, State#{subscribers := lists:delete(Sub, Subs)}};
handle_call(get_header, _From, #{header := Header} = State) ->
    {reply, Header, State};
handle_call({get_by_epoch, Epoch}, _From, #{by_epoch := BE} = State) ->
    {reply, maps:get(Epoch, BE, []), State};
handle_call({get_lines_by_epoch, Epoch}, _From, #{lines_by_epoch := LBE} = State) ->
    {reply, maps:get(Epoch, LBE, []), State};
handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({wiring_update, _Up, _Down, WiringRef, From}, State) ->
    From ! {wiring_ack, WiringRef, self()},
    {noreply, State};
handle_info({delta, Meta, Deltas, _From}, State) ->
    Epoch = maps:get(epoch, Meta),
    IsDone = maps:get(barrier, Meta, undefined) =:= epoch_done,
    State1 = ingest(Epoch, Deltas, IsDone, State),
    {noreply, State1};
handle_info({await_epoch_done, Epoch, From, Ref}, State) ->
    State1 = maybe_reply_waiter(Epoch, From, Ref, State),
    {noreply, State1};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

ingest(Epoch, Deltas, IsDone, State) ->
    Type = maps:get(type, State),
    Subs = maps:get(subscribers, State),
    {ByEpoch, LinesByEpoch} = lists:foldl(
        fun({W, Row}, {BE, LBE}) ->
            Line = [W, gdbsp_value_json:encode_field(Type, Row)],
            lists:foreach(fun(S) -> S ! {output_line, Line} end, Subs),
            Prev = maps:get(Epoch, BE, []),
            PrevL = maps:get(Epoch, LBE, []),
            {BE#{Epoch => Prev ++ [{W, Row}]},
             LBE#{Epoch => PrevL ++ [Line]}}
        end,
        {maps:get(by_epoch, State), maps:get(lines_by_epoch, State)},
        Deltas),
    State1 = State#{by_epoch := ByEpoch, lines_by_epoch := LinesByEpoch},
    case IsDone of
        true ->
            lists:foreach(fun(S) -> S ! {output_epoch_done, Epoch} end, Subs),
            notify_waiters(Epoch, State1),
            State1#{done_epochs := [Epoch | maps:get(done_epochs, State1)]};
        false ->
            State1
    end.

maybe_reply_waiter(Epoch, From, Ref, #{done_epochs := Done} = State) ->
    case lists:member(Epoch, Done) of
        true ->
            From ! {epoch_done, Ref},
            State;
        false ->
            Waiters = maps:get(waiters, State),
            Existing = maps:get(Epoch, Waiters, []),
            State#{waiters := Waiters#{Epoch => [{From, Ref} | Existing]}}
    end.

notify_waiters(Epoch, #{waiters := Waiters}) ->
    case maps:find(Epoch, Waiters) of
        {ok, List} ->
            lists:foreach(fun({From, Ref}) -> From ! {epoch_done, Ref} end, List);
        error ->
            ok
    end.
