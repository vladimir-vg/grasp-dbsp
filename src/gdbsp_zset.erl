-module(gdbsp_zset).

-export([
    from_list/1, to_list/1, is_empty/1, size/1,
    merge/2, subtract_weights/2,
    apply_deltas/2, normalize_vals/1
]).

-type data() :: term().
-type weight() :: integer().
-type key() :: term().
-type value() :: term().

-opaque zset() :: #{data() => weight()}.

-export_type([zset/0, data/0, weight/0, key/0, value/0]).

-spec from_list([{weight(), data()}]) -> zset().
from_list(List) ->
    lists:foldl(
        fun({W, D}, Acc) ->
            Old = maps:get(D, Acc, 0),
            NewW = Old + W,
            if
                NewW =:= 0 -> maps:remove(D, Acc);
                true -> Acc#{D => NewW}
            end
        end,
        #{},
        List
    ).

-spec to_list(zset()) -> [{weight(), data()}].
to_list(ZSet) ->
    lists:sort([{W, D} || {D, W} <- maps:to_list(ZSet)]).

-spec is_empty(zset()) -> boolean().
is_empty(ZSet) -> map_size(ZSet) =:= 0.

-spec size(zset()) -> non_neg_integer().
size(ZSet) -> map_size(ZSet).

-spec merge(zset(), zset()) -> zset().
merge(A, B) ->
    maps:fold(
        fun(D, W, Acc) ->
            Old = maps:get(D, Acc, 0),
            NewW = Old + W,
            if
                NewW =:= 0 -> maps:remove(D, Acc);
                true -> Acc#{D => NewW}
            end
        end,
        A,
        B
    ).

-spec subtract_weights(zset(), zset()) -> zset().
subtract_weights(New, Old) ->
    Acc0 = maps:fold(
        fun(D, W, Acc) ->
            OldW = maps:get(D, Old, 0),
            Diff = W - OldW,
            if
                Diff =:= 0 -> Acc;
                true -> Acc#{D => Diff}
            end
        end,
        #{},
        New
    ),
    maps:fold(
        fun(D, W, Acc) ->
            case maps:is_key(D, New) of
                true -> Acc;
                false -> Acc#{D => -W}
            end
        end,
        Acc0,
        Old
    ).

-spec apply_deltas([{weight(), data()}], zset()) -> zset().
apply_deltas(Deltas, ZSet) ->
    lists:foldl(
        fun({W, D}, Acc) ->
            Old = maps:get(D, Acc, 0),
            New = Old + W,
            case New of
                0 -> maps:remove(D, Acc);
                _ -> Acc#{D => New}
            end
        end,
        ZSet,
        Deltas
    ).

-spec normalize_vals([{integer(), term()}]) -> [{integer(), term()}].
normalize_vals(L) -> L.
