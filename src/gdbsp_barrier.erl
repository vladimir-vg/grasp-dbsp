%%%-------------------------------------------------------------------
%%% @doc Barrier synchronization state machine for recursive DBSP
%%% operators.
%%%
%%% FIFO buffer per key. Barrier messages with non-empty deltas are
%%% split: deltas are prepended as an eager non-barrier entry, then the
%%% barrier is appended with empty deltas. Flush commits when every key
%%% has the same barrier tag at the head of its buffer (after skipping
%%% non-barrier entries). After flush, remaining entries become visible
%%% for the next round — no current_barrier / done tracking needed.
%%%
%%% Returns delta messages with full Meta (epoch, barrier tag) so
%%% the calling operator can forward them to downstreams directly.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_barrier).

-export([init/1, record/3]).

-type tag() :: epoch_done | {iter, non_neg_integer(), non_neg_integer()}.

-opaque barrier_state() :: #{
    buf := #{term() => [{tag() | undefined, map(), [term()]}]}
}.

-export_type([tag/0, barrier_state/0]).

%%====================================================================
%% API
%%====================================================================

-spec init([term()]) -> barrier_state().
init(Keys) ->
    #{
        buf => maps:from_list([{K, []} || K <- Keys])
    }.

-spec record(barrier_state(), term(), {delta, map(), [term()]}) ->
    {ok, barrier_state(), #{term() => {delta, map(), [term()], term()}}} |
    {error, term()}.
record(#{buf := Buf} = State, Key, {delta, Meta, Deltas}) ->
    #{epoch := _} = Meta,
    case maps:is_key(Key, Buf) of
        false ->
            {error, {unknown_key, Key}};
        true ->
            Tag = maps:get(barrier, Meta, undefined),
            State2 = case Tag of
                undefined ->
                    append_buf(State, Key, undefined, Meta, Deltas);
                _ ->
                    S1 = case Deltas of
                        []  -> State;
                        _   -> append_buf(State, Key, undefined, Meta, Deltas)
                    end,
                    append_buf(S1, Key, Tag, Meta#{barrier := Tag}, [])
            end,
            case try_flush(maps:get(buf, State2)) of
                {ok, NewBuf, Acc} -> {ok, State2#{buf := NewBuf}, Acc};
                {error, _} = Error -> Error
            end
    end.

%%====================================================================
%% Internal — try_flush
%%====================================================================

%% Single-key case: no synchronization needed. Flush non-barrier
%% entries eagerly, one per call, as long as no barrier is queued.
try_flush(Buf) when map_size(Buf) =:= 1 ->
    [Key] = maps:keys(Buf),
    Entries = maps:get(Key, Buf),
    case has_barrier(Entries) of
        false ->
            case Entries of
                [{undefined, Meta, Deltas} | _] ->
                    Msg = {delta, Meta, Deltas, Key},
                    NewBuf = Buf#{Key := tl(Entries)},
                    {ok, NewBuf, #{Key => Msg}};
                _ ->
                    {ok, Buf, #{}}
            end;
        true ->
            try_flush_multi(Buf)
    end;
try_flush(Buf) ->
    try_flush_multi(Buf).

has_barrier([]) -> false;
has_barrier([{Tag, _, _} | _]) when Tag =/= undefined -> true;
has_barrier([_ | Rest]) -> has_barrier(Rest).

try_flush_multi(Buf) ->
    Firsts = maps:map(fun(_K, E) -> find_first_barrier(E) end, Buf),
    case lists:all(fun({_, T}) -> T =/= undefined end, maps:values(Firsts)) of
        false -> {ok, Buf, #{}};
        true ->
            Tags = lists:usort([T || {_, T} <- maps:values(Firsts)]),
            case Tags of
                [Tag] ->
                    {NewBuf, Acc} = maps:fold(
                        fun(Key, Entries, {B, A}) ->
                            {Window, Rest} = take_until_barrier(Entries, Tag),
                            case build_output_msg(Window, Tag, Key) of
                                undefined -> {B, A};
                                Msg       -> {B#{Key => Rest}, A#{Key => Msg}}
                            end
                        end, {Buf, #{}}, Buf),
                    {ok, NewBuf, Acc};
                _ ->
                    {error, {tag_mismatch, Tags}}
            end
    end.

find_first_barrier([]) -> {first, undefined};
find_first_barrier([{Tag, _, _} | _]) when Tag =/= undefined -> {first, Tag};
find_first_barrier([_ | Rest]) -> find_first_barrier(Rest).

%%====================================================================
%% Internal — flush logic
%%====================================================================

build_output_msg([], _Tag, _Key) ->
    undefined;
build_output_msg(Window, Tag, Key) ->
    Deltas = lists:append([Ds || {_, _, Ds} <- Window]),
    {_, LastMeta, _} = lists:last(Window),
    Meta = LastMeta#{barrier => Tag},
    {delta, Meta, Deltas, Key}.

take_until_barrier([], _Tag) ->
    {[], []};
take_until_barrier([{Tag, _Meta, _Deltas} = Entry | Rest], Tag) ->
    {[Entry], Rest};
take_until_barrier([Entry | Rest], Tag) ->
    {Window, Leftover} = take_until_barrier(Rest, Tag),
    {[Entry | Window], Leftover}.

%%====================================================================
%% Internal — helpers
%%====================================================================

append_buf(#{buf := Buf} = State, Key, Tag, Meta, Deltas) ->
    Old = maps:get(Key, Buf),
    State#{buf := Buf#{Key := Old ++ [{Tag, Meta, Deltas}]}}.
