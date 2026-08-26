%%%-------------------------------------------------------------------
%%% @doc Unit-batch ingress coordinator.
%%%
%%% Owns the epoch counter and a row buffer per input table. Commits
%%% one epoch at a time: each epoch consumes at most one row from each
%%% table (an empty batch for tables with no pending row) and injects an
%%% epoch_done barrier into every source. Rows are opaque {Weight, Row}
%%% deltas — decoding happens upstream.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_ingress).
-behaviour(gen_server).

-export([start_link/1]).
-export([feed/3, mark_exhausted/2, step/1, epoch/1, is_exhausted/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%%====================================================================
%% API
%%====================================================================

%% Inputs :: #{Table :: binary() => InputNodePid :: pid()}
-spec start_link(#{binary() => pid()}) -> {ok, pid()} | {error, term()}.
start_link(Inputs) ->
    gen_server:start_link(?MODULE, Inputs, []).

-spec feed(pid(), binary(), [{integer(), term()}]) -> ok.
feed(Pid, Table, Rows) ->
    gen_server:call(Pid, {feed, Table, Rows}).

-spec mark_exhausted(pid(), binary()) -> ok.
mark_exhausted(Pid, Table) ->
    gen_server:call(Pid, {exhaust, Table}).

%% @doc Commit one epoch if any table has a pending row. Returns
%% {ok, Epoch} on commit, or exhausted when every table is exhausted
%% and no rows are buffered.
-spec step(pid()) -> {ok, non_neg_integer()} | exhausted | idle.
step(Pid) ->
    gen_server:call(Pid, step).

-spec epoch(pid()) -> non_neg_integer().
epoch(Pid) ->
    gen_server:call(Pid, epoch).

-spec is_exhausted(pid()) -> boolean().
is_exhausted(Pid) ->
    gen_server:call(Pid, is_exhausted).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Inputs) ->
    Tables = maps:keys(Inputs),
    {ok, #{
        inputs => Inputs,
        buffers => maps:from_list([{T, queue:new()} || T <- Tables]),
        exhausted => sets:new(),
        epoch => 0
    }}.

handle_call({feed, Table, Rows}, _From, #{buffers := Buffers} = State) ->
    Buf = maps:get(Table, Buffers, queue:new()),
    Buf2 = lists:foldl(fun queue:in/2, Buf, Rows),
    {reply, ok, State#{buffers := Buffers#{Table => Buf2}}};
handle_call({exhaust, Table}, _From, #{exhausted := Exh} = State) ->
    {reply, ok, State#{exhausted := sets:add_element(Table, Exh)}};
handle_call(step, _From, State) ->
    case commit_epoch(State) of
        {State1, Epoch} -> {reply, {ok, Epoch}, State1};
        Result -> {reply, Result, State}
    end;
handle_call(epoch, _From, #{epoch := Epoch} = State) ->
    {reply, Epoch, State};
handle_call(is_exhausted, _From, State) ->
    {reply, all_exhausted(State), State};
handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

has_pending(#{buffers := Buffers}) ->
    maps:fold(fun(_T, Buf, Acc) -> Acc orelse not queue:is_empty(Buf) end,
              false, Buffers).

all_exhausted(#{buffers := Buffers, exhausted := Exh}) ->
    AllExhausted = maps:fold(
        fun(Table, _Buf, Acc) -> Acc andalso sets:is_element(Table, Exh) end,
        true, Buffers),
    AllExhausted andalso not has_pending(#{buffers => Buffers}).

commit_epoch(#{buffers := Buffers, inputs := Inputs, epoch := Epoch} = State) ->
    case {has_pending(State), all_exhausted(State)} of
        {false, true} -> exhausted;
        {false, false} -> idle;
        {true, _} ->
            Epoch1 = Epoch + 1,
            {Buffers1, Deliveries} = maps:fold(
                fun(Table, Buf, {BAcc, DAcc}) ->
                    {Row, Buf1} = case queue:out(Buf) of
                        {empty, Q} -> {[], Q};
                        {{value, R}, Q} -> {[R], Q}
                    end,
                    {BAcc#{Table => Buf1}, DAcc#{Table => Row}}
                end,
                {Buffers, #{}},
                Buffers),
            maps:foreach(
                fun(Table, Row) ->
                    InputPid = maps:get(Table, Inputs),
                    InputPid ! {delta, #{epoch => Epoch1}, Row, self()},
                    InputPid ! {delta, #{epoch => Epoch1, barrier => epoch_done},
                                [], self()}
                end,
                Deliveries),
            {State#{buffers := Buffers1, epoch := Epoch1}, Epoch1}
    end.
