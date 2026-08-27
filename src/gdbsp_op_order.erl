%%%-------------------------------------------------------------------
%%% @doc Barrier-aware ordering (ORDER BY) via occurrence expansion.
%%%
%%% Maintains the full input multiset (seen) and the previous ranked
%%% output multiset (prev). Deltas are buffered between barriers. On
%%% barrier the buffer is applied to seen, each distinct row is expanded
%%% to its multiplicity of occurrences, occurrences are sorted by the
%%% `by` keys (per-key direction), and each occurrence is emitted with a
%%% `rank` (SQL RANK — ties share, gaps follow) and a unique 1..N
%%% `row_number`. Output is diffed against prev so rank/row_number shifts
%%% cascade correctly.
%%%
%%% Weight 1 output rows. Ties on the full sort-key tuple are broken by
%%% the row's canonical (field-sorted) encoding for a deterministic order.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_order).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type direction() :: asc | desc.
-type order_key() :: {binary(), direction()}.

-type op_state() :: #{
    by                := [order_key()],
    rank_col          := binary(),
    row_number_col    := binary(),
    seen              := #{term() => integer()},
    prev              := #{term() => integer()},
    buffer            := [{integer(), term()}],
    downstream_label  := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{by := BySpec, rank_col := RankCol, row_number_col := RowNumCol}) ->
    {#{by => normalize_by(BySpec),
       rank_col => RankCol,
       row_number_col => RowNumCol,
       seen => #{}, prev => #{}, buffer => [],
       downstream_label => default},
     [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{buffer := Buf, downstream_label := Label} = St,
             default, {delta, Meta, Deltas}) ->
    NewBuf = Buf ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, state_reset} ->
            {St#{seen := #{}, prev := #{}, buffer := []},
             [{send, Label, {delta, Meta, []}}]};
        {ok, _} ->
            {St2, Output} = compute_order(St#{buffer := NewBuf}),
            Actions = case Output of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, Output}}]
            end,
            {St2#{buffer := []}, Actions};
        error ->
            {St#{buffer := NewBuf}, []}
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.

%%====================================================================
%% Internal
%%====================================================================

normalize_by(BySpec) ->
    [{F, direction(D)} || [F, D] <- BySpec].

direction(<<"desc">>) -> desc;
direction(_) -> asc.

compute_order(#{buffer := Buf, seen := Seen, prev := Prev, by := By,
                rank_col := RankCol, row_number_col := RowNumCol} = St) ->
    Seen2 = gdbsp_zset:apply_deltas(Buf, Seen),
    NewOut = rank_rows(Seen2, By, RankCol, RowNumCol),
    Diff = gdbsp_zset:subtract_weights(NewOut, Prev),
    Output = sort_by_row_number(gdbsp_zset:to_list(Diff), RowNumCol),
    {St#{seen := Seen2, prev := NewOut}, Output}.

sort_by_row_number(Rows, RowNumCol) ->
    lists:sort(
        fun({_, A}, {_, B}) ->
            {row_number_of(A, RowNumCol), A} =< {row_number_of(B, RowNumCol), B}
        end, Rows).

row_number_of({value, {struct, _, _}, TypedValues}, RowNumCol) ->
    case maps:get(RowNumCol, TypedValues) of
        {value, _, N} -> N;
        N -> N
    end.

rank_rows(Seen, By, RankCol, RowNumCol) ->
    Entries = [{Row, W, key_list(Row, By), canonical_row(Row)}
               || {Row, W} <- maps:to_list(Seen)],
    Cmp = fun({_, _, KA, CA}, {_, _, KB, CB}) ->
        case compare_key_list(KA, KB, By) of
            eq  -> CA =< CB;
            lt  -> true;
            gt  -> false
        end
    end,
    Sorted = lists:sort(Cmp, Entries),
    {RowsOut, _Pos, _CurRank, _PrevKey} =
        lists:foldl(
            fun({Row, W, Keys, _}, {Acc, Pos, CurRank, PrevKey}) ->
                {NewRank, NewPrevKey} =
                    case Keys =:= PrevKey of
                        true  -> {CurRank, PrevKey};
                        false -> {Pos + 1, Keys}
                    end,
                Emitted = [{1, emit(Row, RowNum, NewRank, RankCol, RowNumCol)}
                           || RowNum <- lists:seq(Pos + 1, Pos + W)],
                {Emitted ++ Acc, Pos + W, NewRank, NewPrevKey}
            end,
            {[], 0, 0, undefined},
            Sorted),
    gdbsp_zset:from_list(RowsOut).

emit(Row, RowNum, Rank, RankCol, RowNumCol) ->
    Row1 = gdbsp_value:struct_extend(Row, RankCol, {value, integer, Rank}),
    gdbsp_value:struct_extend(Row1, RowNumCol, {value, integer, RowNum}).

%%====================================================================
%% Sort-key extraction & comparison
%%====================================================================

key_list({value, {struct, _, _}, TypedValues}, By) ->
    [maps:get(F, TypedValues) || {F, _} <- By].

canonical_row({value, {struct, _, _}, TypedValues}) ->
    lists:sort(maps:to_list(TypedValues)).

compare_key_list([VA | KA], [VB | KB], [{_, Dir} | ByRest]) ->
    case compare_value(VA, VB) of
        eq -> compare_key_list(KA, KB, ByRest);
        lt when Dir =:= asc  -> lt;
        lt when Dir =:= desc -> gt;
        gt when Dir =:= asc  -> gt;
        gt when Dir =:= desc -> lt
    end;
compare_key_list([], [], []) ->
    eq.

%% Three-way comparison of typed values. numeric uses decimal:fast_cmp;
%% f32/f64 account for infinity/neg_infinity/nan; everything else uses
%% Erlang term order on the raw value.
compare_value({value, numeric, A}, {value, numeric, B}) ->
    decimal_cmp(A, B);
compare_value({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    decimal_cmp(A, B);
compare_value({value, f64, A}, {value, f64, B}) ->
    float_cmp(A, B);
compare_value({value, f32, A}, {value, f32, B}) ->
    float_cmp(A, B);
compare_value(A, B) when A =:= B -> eq;
compare_value(A, B) when A < B -> lt;
compare_value(_, _) -> gt.

decimal_cmp(A, B) ->
    case decimal:fast_cmp(A, B) of
        -1 -> lt;
        0  -> eq;
        1  -> gt
    end.

float_cmp(A, B) ->
    case {A, B} of
        {nan, nan} -> eq;
        {nan, _} -> gt;
        {_, nan} -> lt;
        {neg_infinity, neg_infinity} -> eq;
        {neg_infinity, _} -> lt;
        {_, neg_infinity} -> gt;
        {infinity, infinity} -> eq;
        {infinity, _} -> gt;
        {_, infinity} -> lt;
        _ when A =:= B -> eq;
        _ when A < B -> lt;
        _ -> gt
    end.
