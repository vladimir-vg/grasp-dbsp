%%%-------------------------------------------------------------------
%%% @doc Expression tree evaluator.
%%%
%%% eval_with_blob — resolves blob() references by fetching from blob
%%% storage. No {arg, _} nodes allowed in blob context.
%%%
%%% eval_with_row — resolves {arg, _} and {call, ...} against a struct row.
%%% Supports {agg, ...} nodes (caller provides accumulator context).
%%% No blob resolution.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_eval).

-include("gdbsp_expr.hrl").

%% ── Core evaluators ─────────────────────────────────────────────────
-export([eval_with_blob/2, eval_with_row/2]).
-export([eval_with_blob_batch/2]).

%%====================================================================
%% eval_with_blob
%%====================================================================

-type blob_fetcher() :: mfa().

-spec eval_with_blob(expr(), blob_fetcher()) ->
    {ok, value()} | drop_row | {error, term()}.
eval_with_blob(Expr, Fetcher) ->
    do_eval(Expr, {blob, Fetcher}).

%%====================================================================
%% eval_with_row
%%====================================================================

-spec eval_with_row(expr(), value()) ->
    {ok, value()} | drop_row | {error, term()}.
eval_with_row(Expr, {value, {struct, _Fields, _Rest}, _Data} = Row) ->
    do_eval(Expr, {row, Row});
eval_with_row(_Expr, _NotAStruct) ->
    {error, {eval_with_row_requires_struct_value, _NotAStruct}}.

%%====================================================================
%% eval_with_blob_batch
%%====================================================================

-spec eval_with_blob_batch([expr()], blob_fetcher()) ->
    {ok, [{ok, value()} | null]}.
eval_with_blob_batch(Exprs, Fetcher) ->
    {ok, [case eval_with_blob(E, Fetcher) of
              {ok, V} -> {ok, V};
              drop_row -> null;
              {error, _} -> null
          end || E <- Exprs]}.

%%====================================================================
%% do_eval — dispatches on context type and expr node type
%%====================================================================

%% A type literal expr leaf lowers to the distinct `{type, T}` argument term —
%% a type is not a runtime value (value-type-representation-hardening.md §5).
do_eval({value, type, T}, _Ctx) ->
    {ok, {type, T}};
do_eval({value, _, _} = V, _Ctx) ->
    {ok, V};
do_eval({arg, <<"row">>}, {row, Row}) -> {ok, Row};
do_eval({arg, _}, _Ctx) -> {error, unknown_arg};
do_eval({call, <<"storage:blob">>, [], Kw}, {blob, Fetcher}) ->
    resolve_blob(Kw, Fetcher);
do_eval({call, <<"storage:blob">>, _, _}, {row, _Row}) ->
    {error, blob_resolution_not_allowed_in_row_eval};
do_eval({call, Name, PosArgs, KwArgs}, Ctx) ->
    eval_call(Name, PosArgs, KwArgs, Ctx);
do_eval({get, Obj, Keys}, Ctx) ->
    case do_eval(Obj, Ctx) of
        {ok, ObjVal} -> eval_get(ObjVal, Keys, Ctx);
        drop_row -> drop_row;
        {error, _} = E -> E
    end;
do_eval({slice, Obj, Start, Stop, Step}, Ctx) ->
    case do_eval(Obj, Ctx) of
        {ok, ObjVal} -> eval_slice(ObjVal, Start, Stop, Step, Ctx);
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

%%====================================================================
%% eval_call
%%====================================================================

eval_call(Name, PosArgs, KwArgs, Ctx) ->
    case eval_args(PosArgs, KwArgs, Ctx) of
        {ok, PosValues, KwValues} ->
            dispatch_call(Name, PosValues, KwValues);
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

call_impl(Mod, Fun, PosValues, KwValues) ->
    try
        case maps:size(KwValues) of
            0 ->
                apply(Mod, Fun, PosValues);
            _ ->
                apply(Mod, Fun, kw_pos_args(PosValues, KwValues, Mod, Fun))
        end
    of
        Result -> {ok, Result}
    catch
        throw:drop_row -> drop_row;
        error:undef -> {error, {undefined_function, Mod, Fun}};
        error:function_clause -> {error, {function_clause, Mod, Fun}};
        _:Reason -> {error, {call_failed, Mod, Fun, Reason}}
    end.

kw_pos_args(PosValues, KwValues, Mod, Fun) ->
    Arity = proplists:get_value(Fun,
        Mod:module_info(exports), 0),
    AllArgs = PosValues ++ maps:values(KwValues),
    case length(AllArgs) >= Arity of
        true -> lists:sublist(AllArgs, Arity);
        false -> AllArgs
    end.

%%====================================================================
%% eval_args
%%====================================================================

eval_args(PosArgs, KwArgs, Ctx) ->
    case eval_arg_list(PosArgs, [], Ctx) of
        {ok, PosValues} ->
            case eval_kw_args(maps:to_list(KwArgs), #{}, Ctx) of
                {ok, KwValues} -> {ok, PosValues, KwValues};
                drop_row -> drop_row;
                {error, _} = E -> E
            end;
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

eval_arg_list([], Acc, _Ctx) -> {ok, lists:reverse(Acc)};
eval_arg_list([H | T], Acc, Ctx) ->
    case do_eval(H, Ctx) of
        {ok, V} -> eval_arg_list(T, [V | Acc], Ctx);
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

eval_kw_args([], Acc, _Ctx) -> {ok, Acc};
eval_kw_args([{K, V} | T], Acc, Ctx) ->
    case do_eval(V, Ctx) of
        {ok, Val} -> eval_kw_args(T, Acc#{K => Val}, Ctx);
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

%%====================================================================
%% resolve_blob
%%====================================================================

resolve_blob(Kw, {M, F, PreArgs}) ->
    try
        case {maps:find(<<"sha256">>, Kw), maps:find(<<"git_sha1">>, Kw)} of
            {{ok, {value, _, Hash}}, _} when is_binary(Hash) ->
                fetch_blob({M, F, PreArgs}, sha256, Hash);
            {_, {ok, {value, _, Hash}}} when is_binary(Hash) ->
                fetch_blob({M, F, PreArgs}, git_sha1, Hash);
            _ ->
                {error, {blob_requires_sha256_or_git_sha1_key}}
        end
    catch
        throw:drop_row -> drop_row
    end.

fetch_blob({M, F, PreArgs}, Algo, Hash) ->
    case apply(M, F, PreArgs ++ [Algo, binary_to_list(Hash)]) of
        {ok, Data} ->
            {ok, {value, bytes, Data}};
        {error, not_found} ->
            erlang:throw(drop_row)
    end.

%%====================================================================
%% eval_get
%%====================================================================

eval_get(ObjVal, Keys, Ctx) ->
    case eval_arg_list(Keys, [], Ctx) of
        {ok, KeyVals} ->
            apply_get(ObjVal, KeyVals);
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

apply_get(V, []) -> {ok, V};
apply_get({value, {struct, _Fields, _SRest}, _Data} = Obj, [Key | Rest]) ->
    try gdbsp_struct:struct_get(Obj, Key) of
        Val -> apply_get(Val, Rest)
    catch
        throw:drop_row -> drop_row
    end;
apply_get({value, {array, _ET, _Shape}, List}, [Key | Rest]) when is_list(List) ->
    Len = length(List),
    Idx = clamp_index(Key, Len),
    case Idx >= 0 andalso Idx < Len of
        true -> apply_get(lists:nth(Idx + 1, List), Rest);
        false -> drop_row
    end;
apply_get({value, {map, _K, _V}, MapData}, [Key | Rest]) when is_map(MapData) ->
    KeyTerm = key_of(Key),
    case maps:find(KeyTerm, MapData) of
        {ok, Val} -> apply_get(Val, Rest);
        error -> drop_row
    end;
apply_get({value, {json, {array, json, _}}, V}, [Key | Rest]) when is_list(V) ->
    Len = length(V),
    Idx = clamp_index(Key, Len),
    case Idx >= 0 andalso Idx < Len of
        true -> apply_get(lists:nth(Idx + 1, V), Rest);
        false -> drop_row
    end;
apply_get({value, {json, {map, string, json}}, V}, [Key | Rest]) when is_map(V) ->
    KeyTerm = key_of(Key),
    case maps:find(KeyTerm, V) of
        {ok, Val} -> apply_get(Val, Rest);
        error -> drop_row
    end;
apply_get({value, {dynamic, {array, ET, _}}, V}, [Key | Rest]) when is_list(V) ->
    Len = length(V),
    Idx = clamp_index(Key, Len),
    case Idx >= 0 andalso Idx < Len of
        true ->
            {value, ET, RawElem} = lists:nth(Idx + 1, V),
            apply_get({value, {dynamic, ET}, RawElem}, Rest);
        false -> drop_row
    end;
apply_get({value, {dynamic, {map, _KT, VT}}, V}, [Key | Rest]) when is_map(V) ->
    KeyTerm = key_of(Key),
    case maps:find(KeyTerm, V) of
        {ok, {value, VT, RawVal}} -> apply_get({value, {dynamic, VT}, RawVal}, Rest);
        error -> drop_row
    end;
apply_get({value, _, _} = V, []) -> {ok, V};
apply_get(_, []) -> {ok, {value, {dynamic, absent}, none}};
apply_get(_, _) ->
    {error, {cannot_index_non_container}}.

key_of({value, string, K}) -> K;
key_of({value, {string, _}, K}) -> K;
key_of({value, i64, K}) -> K;
key_of({value, integer, K}) -> K;
key_of({value, _, K}) -> K.

%%====================================================================
%% eval_slice
%%====================================================================

eval_slice(ObjVal, Start, Stop, Step, Ctx) ->
    case eval_slice_bounds(Start, Stop, Step, Ctx) of
        {ok, StartVal, StopVal, StepVal} ->
            apply_slice(ObjVal, StartVal, StopVal, StepVal);
        drop_row -> drop_row;
        {error, _} = E -> E
    end.

eval_slice_bounds(Start, Stop, Step, Ctx) ->
    try
        {ok, StartVal} = evaluate_bound(Start, Ctx),
        {ok, StopVal}  = evaluate_bound(Stop, Ctx),
        {ok, StepVal}  = evaluate_bound(Step, Ctx),
        {ok, StartVal, StopVal, StepVal}
    catch
        throw:drop_row -> drop_row;
        error:{badmatch, {error, _} = E} -> E
    end.

evaluate_bound(undefined, _Ctx) -> {ok, undefined};
evaluate_bound(Expr, Ctx) -> do_eval(Expr, Ctx).

apply_slice({value, string, S}, Start, Stop, Step) ->
    Graphemes = unicode:characters_to_list(S),
    Len = length(Graphemes),
    S0 = bound_int(Start, 0),
    E0 = bound_int(Stop, Len),
    St = bound_int(Step, 1),
    case St of
        0 -> {error, {slice_step_cannot_be_zero}};
        _ ->
            Sliced = slice_list(Graphemes, S0, E0, St),
            {ok, {value, string, unicode:characters_to_binary(Sliced)}}
    end;
apply_slice({value, bytes, Bin}, Start, Stop, Step) ->
    Len = byte_size(Bin),
    S0 = bound_int(Start, 0),
    E0 = bound_int(Stop, Len),
    St = bound_int(Step, 1),
    case St of
        0 -> {error, {slice_step_cannot_be_zero}};
        _ when S0 < E0, St > 0 ->
            {ok, {value, bytes, bytes_slice(Bin, S0, E0, St)}};
        _ when S0 > E0, St < 0 ->
            {ok, {value, bytes, bytes_slice_rev(Bin, S0, E0, St)}};
        _ -> {ok, {value, bytes, <<>>}}
    end;
apply_slice({value, {bytes, _N}, Bin}, Start, Stop, Step) ->
    apply_slice({value, bytes, Bin}, Start, Stop, Step);
apply_slice({value, {array, ET, _Shape}, List}, Start, Stop, Step) ->
    Len = length(List),
    S0 = bound_int(Start, 0),
    E0 = bound_int(Stop, Len),
    St = bound_int(Step, 1),
    case St of
        0 -> {error, {slice_step_cannot_be_zero}};
        _ ->
            Sliced = slice_list(List, S0, E0, St),
            {ok, {value, {array, ET, varsize}, Sliced}}
    end;
apply_slice({value, bits, Bin}, Start, Stop, Step) ->
    Len = bit_size(Bin),
    S0 = bound_int(Start, 0),
    E0 = bound_int(Stop, Len),
    St = bound_int(Step, 1),
    case St of
        0 -> {error, {slice_step_cannot_be_zero}};
        _ when S0 < E0, St > 0 ->
            try
                N = E0 - S0,
                <<_:S0, B:N/bitstring, _/bitstring>> = Bin,
                Sliced = if St =:= 1 -> B;
                            true ->
                                Count = N div St,
                                << <<(bit_at(B, P * St)):1>> || P <- lists:seq(0, Count - 1) >>
                         end,
                {ok, {value, bits, Sliced}}
            catch
                _:_ -> drop_row
            end;
        _ -> {ok, {value, bits, <<>>}}
    end;
apply_slice({value, {bits, _N}, Bin}, Start, Stop, Step) ->
    apply_slice({value, bits, Bin}, Start, Stop, Step);
apply_slice({value, {json, {array, json, _}}, V}, Start, Stop, Step) when is_list(V) ->
    case apply_slice({value, {array, json, varsize}, V}, Start, Stop, Step) of
        {ok, {value, {array, json, varsize}, Sliced}} ->
            {ok, {value, {json, {array, json, varsize}}, Sliced}};
        Other -> Other
    end;
apply_slice({value, {dynamic, _}, V}, Start, Stop, Step) when is_list(V) ->
    apply_slice({value, {array, dynamic, varsize}, V}, Start, Stop, Step);
apply_slice(_, _, _, _) ->
    {error, {cannot_slice_non_sequence}}.

bound_int(undefined, Default) -> Default;
bound_int({value, T, N}, _Default) when T =:= i64; T =:= i8; T =:= i16;
                                           T =:= i32; T =:= u8; T =:= u16;
                                           T =:= u32; T =:= u64;
                                           T =:= integer ->
    N;
bound_int({value, f64, N}, _Default) when is_integer(N) -> N;
bound_int({value, f64, N}, _Default) -> trunc(N);
bound_int({value, f32, N}, _Default) when is_integer(N) -> N;
bound_int({value, f32, N}, _Default) -> trunc(N).

slice_list(List, Start, Stop, Step) when Step > 0, Start < Stop ->
    Sublist = lists:sublist(List, Start + 1, Stop - Start),
    [lists:nth(I, Sublist) || I <- lists:seq(1, length(Sublist), Step)];
slice_list(List, Start, Stop, Step) when Step < 0, Start > Stop ->
    Sublist = lists:sublist(List, Stop + 1, Start - Stop),
    lists:reverse([lists:nth(I, Sublist) || I <- lists:seq(1, length(Sublist), abs(Step))]);
slice_list(_, _, _, _) -> [].

bytes_slice(Bin, Start, Stop, Step) ->
    Positions = lists:seq(Start, Stop - 1, Step),
    << <<(binary:at(Bin, P))>> || P <- Positions >>.

bytes_slice_rev(Bin, Start, Stop, Step) ->
    Positions = lists:seq(Start, Stop + 1, Step),
    << <<(binary:at(Bin, P))>> || P <- Positions >>.

bit_at(Bin, Pos) ->
    <<_:Pos, B:1, _/bitstring>> = Bin,
    B.

clamp_index({value, T, N}, Len) when T =:= i64; T =:= i8; T =:= i16;
                                       T =:= i32; T =:= u8; T =:= u16;
                                       T =:= u32; T =:= u64;
                                       T =:= integer ->
    case N < 0 of
        true -> clamp_nonneg(Len + N, Len);
        false -> clamp_nonneg(N, Len)
    end.

clamp_nonneg(N, _Len) when N < 0 -> 0;
clamp_nonneg(N, Len) when N > Len -> Len;
clamp_nonneg(N, _Len) -> N.

%%====================================================================
%% Helpers
%%====================================================================

type_of({value, {dynamic, T}, _V}) -> {dynamic, T};
type_of({type, _}) -> type;
type_of({value, Type, _Data}) -> Type.

dispatch_call(<<"map">>, _PosValues, KwValues) ->
    ConcreteV = case maps:values(KwValues) of
        [] -> dynamic;
        Vs -> element(2, lists:last(Vs))
    end,
    {ok, {value, {map, string, ConcreteV}, maps:map(fun(_K, V) -> V end, KwValues)}};
dispatch_call(<<"array">>, PosValues, _KwValues) ->
    ConcreteE = case PosValues of
        [] -> dynamic;
        _ -> element(2, lists:last(PosValues))
    end,
    {ok, {value, {array, ConcreteE, varsize}, PosValues}};
dispatch_call(<<"struct">>, _PosValues, KwValues) ->
    Fields = maps:map(fun(_K, V) -> element(2, V) end, KwValues),
    {ok, {value, {struct, Fields, exact}, KwValues}};
dispatch_call(<<"struct:get">>, PosValues, KwValues) ->
    dispatch_call(<<"std.struct_get">>, PosValues, KwValues);
dispatch_call(Name, PosValues, KwValues) ->
    PosTypes = [type_of(V) || V <- PosValues],
    KwPairs = [{K, type_of(V)} || {K, V} <- maps:to_list(KwValues)],
    Concrete = case gdbsp_builtins:concrete_fn(Name, PosTypes, maps:from_list(KwPairs)) of
        {error, not_an_operator} -> Name;
        CN -> CN
    end,
    case gdbsp_builtins:fn_impl(Concrete) of
        {ok, {Mod, Fun, _Arity}} ->
            call_impl(Mod, Fun, PosValues, KwValues);
        {error, unknown_impl} ->
            {error, {no_implementation, Name}};
        {error, _} = E -> E
    end.
