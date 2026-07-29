%%%-------------------------------------------------------------------
%%% @doc Expression tree JSON serialization and deserialization.
%%%
%%% Converts between expr() (gdbsp_expr.hrl) and JSON (jsx terms).
%%% Value encoding follows grasp-value-type-json-format.md.
%%% Provides validation helpers for node presence checks.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_expr).

-include("gdbsp_expr.hrl").

%% ── JSON <> expr conversion ─────────────────────────────────────────
-export([expr_to_json/1, json_to_expr/1]).

%% ── Validation helpers ──────────────────────────────────────────────
-export([has_field_nodes/1, has_blob_calls/1]).

%%====================================================================
%% expr_to_json
%%====================================================================

-spec expr_to_json(expr()) -> jsx:json_term().
expr_to_json({value, {closure, _Params, _Return}, InnerExpr}) ->
    expr_to_json(InnerExpr);
expr_to_json({value, Type, Data}) ->
    #{<<"type">> => gdbsp_type:type_to_json(Type),
      <<"value">> => encode_value(Type, Data)};
expr_to_json({field, Name}) ->
    #{<<"field">> => Name};
expr_to_json({call, Name, PosArgs, KwArgs}) ->
    call_to_json(<<"call">>, Name, PosArgs, KwArgs);
expr_to_json({agg, Name, PosArgs, KwArgs}) ->
    call_to_json(<<"aggregate">>, Name, PosArgs, KwArgs);
expr_to_json({get, Obj, Keys}) ->
    #{<<"get">> => expr_to_json(Obj),
      <<"keys">> => [expr_to_json(K) || K <- Keys]};
expr_to_json({slice, Obj, Start, Stop, Step}) ->
    M0 = #{<<"slice">> => expr_to_json(Obj)},
    M1 = maybe_add(<<"start">>, Start, M0),
    M2 = maybe_add(<<"stop">>, Stop, M1),
    maybe_add(<<"step">>, Step, M2).

maybe_add(_Key, undefined, M) -> M;
maybe_add(Key, Expr, M) -> M#{Key => expr_to_json(Expr)}.

call_to_json(Tag, Name, PosArgs, KwArgs) ->
    M0 = #{Tag => Name},
    M1 = case PosArgs of
        [] -> M0;
        _ -> M0#{<<"args">> => [expr_to_json(A) || A <- PosArgs]}
    end,
    case maps:size(KwArgs) of
        0 -> M1;
        _ -> M1#{<<"kwargs">> =>
            maps:fold(fun(K, V, Acc) -> Acc#{K => expr_to_json(V)} end, #{}, KwArgs)}
    end.

%%====================================================================
%% encode_value — type-specific value encoding
%%====================================================================

encode_value({enum, [<<"false">>, <<"true">>]}, true) -> <<"true">>;
encode_value({enum, [<<"false">>, <<"true">>]}, false) -> <<"false">>;
encode_value({enum, _}, Name) when is_binary(Name) -> Name;

encode_value(absent, _) -> null;
encode_value({optional, _}, absent) -> null;

encode_value(T, N) when is_integer(N), (
    T =:= i8 orelse T =:= i16 orelse T =:= i32 orelse T =:= i64 orelse
    T =:= u8 orelse T =:= u16 orelse T =:= u32 orelse T =:= u64 orelse
    T =:= integer) ->
    integer_to_binary(N);

encode_value(f64, infinity) -> <<"inf">>;
encode_value(f64, neg_infinity) -> <<"-inf">>;
encode_value(f64, nan) -> <<"nan">>;
encode_value(f64, V) when is_number(V) -> float_to_string(float(V));
encode_value(f32, infinity) -> <<"inf">>;
encode_value(f32, neg_infinity) -> <<"-inf">>;
encode_value(f32, nan) -> <<"nan">>;
encode_value(f32, V) when is_number(V) -> float_to_string(float(V));

encode_value(numeric, {Coeff, Scale}) -> numeric_to_string(Coeff, Scale);
encode_value({numeric, _, _}, {Coeff, Scale}) -> numeric_to_string(Coeff, Scale);

encode_value(string, S) when is_binary(S) -> S;
encode_value({string, _}, S) when is_binary(S) -> S;
encode_value(string_with_encoding, {Enc, S}) ->
    #{<<"encoding">> => Enc, <<"value">> => S};

encode_value(bytes, Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};
encode_value({bytes, _}, Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};
encode_value(bits, Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};
encode_value({bits, _}, Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};

encode_value(date, {Y, M, D}) ->
    #{<<"year">> => integer_to_binary(Y),
      <<"month">> => integer_to_binary(M),
      <<"day">> => integer_to_binary(D)};
encode_value(time, {H, Mi, S, Us}) ->
    #{<<"hour">> => integer_to_binary(H),
      <<"minute">> => integer_to_binary(Mi),
      <<"second">> => integer_to_binary(S),
      <<"microsecond">> => integer_to_binary(Us)};
encode_value(timestamp, Us) ->
    #{<<"epoch_microseconds">> => integer_to_binary(Us)};
encode_value(timestamp_with_timezone, {Us, Offset, Zone}) ->
    M = #{<<"epoch_microseconds">> => integer_to_binary(Us),
          <<"offset_seconds">> => integer_to_binary(Offset)},
    case Zone of
        undefined -> M;
        _ -> M#{<<"zone">> => Zone}
    end;
encode_value(interval, {Months, Days, Us}) ->
    #{<<"months">> => integer_to_binary(Months),
      <<"days">> => integer_to_binary(Days),
      <<"microseconds">> => integer_to_binary(Us)};

encode_value({dynamic, _}, absent) -> null;
encode_value({dynamic, T}, RawVal) ->
    #{<<"type">> => gdbsp_type:type_to_json(T),
      <<"value">> => encode_value(T, RawVal)};

encode_value({json, T}, Data) ->
    gdbsp_value_json:json_node_to_jsx({value, {json, T}, Data});
encode_value(json, Data) ->
    gdbsp_value_json:json_node_to_jsx(Data);

encode_value({array, ET, _}, List) when is_list(List) ->
    [encode_value(ET, El) || El <- List];
encode_value({map, KT, VT}, MapData) when is_map(MapData) ->
    [[encode_value(KT, K), encode_value(VT, V)]
     || {K, V} <- maps:to_list(MapData)];
encode_value({struct, Fields, _Rest}, MapData) when is_map(MapData) ->
    maps:fold(fun(Name, FieldType, Acc) ->
        Val = maps:get(Name, MapData),
        Acc#{Name => encode_value(FieldType, Val)}
    end, #{}, Fields);

encode_value(type, T) -> gdbsp_type:type_to_json(T);

encode_value(_Type, Data) ->
    iolist_to_binary(io_lib:format("~p", [Data])).

%% ── float_to_string ─────────────────────────────────────────────────

float_to_string(V) ->
    iolist_to_binary(io_lib:format("~.17g", [V])).

%% ── numeric_to_string ───────────────────────────────────────────────

numeric_to_string(Coeff, 0) ->
    integer_to_binary(Coeff);
numeric_to_string(Coeff, Scale) when Scale < 0 ->
    DecimalPlaces = -Scale,
    Sign = case Coeff < 0 of true -> <<"-">>; false -> <<>> end,
    AbsCoeff = abs(Coeff),
    CoeffStr = integer_to_list(AbsCoeff),
    Len = length(CoeffStr),
    case DecimalPlaces >= Len of
        true ->
            Padding = lists:duplicate(DecimalPlaces - Len, $0),
            iolist_to_binary([Sign, "0.", Padding, CoeffStr]);
        false ->
            {IntPart, FracPart} = lists:split(Len - DecimalPlaces, CoeffStr),
            iolist_to_binary([Sign, IntPart, ".", FracPart])
    end;
numeric_to_string(Coeff, Scale) when Scale > 0 ->
    integer_to_binary(Coeff * pow10(Scale)).

pow10(0) -> 1;
pow10(N) when N > 0 -> 10 * pow10(N - 1).

%%====================================================================
%% json_to_expr
%%====================================================================

-spec json_to_expr(jsx:json_term()) -> {ok, expr()} | {error, term()}.
json_to_expr(#{<<"field">> := Name}) when is_binary(Name) ->
    {ok, {field, Name}};
json_to_expr(#{<<"call">> := Name} = M) ->
    json_call_to_expr(call, Name, M);
json_to_expr(#{<<"aggregate">> := Name} = M) ->
    json_call_to_expr(agg, Name, M);
json_to_expr(#{<<"get">> := ObjJson} = M) ->
    case json_to_expr(ObjJson) of
        {ok, Obj} ->
            KeysJson = maps:get(<<"keys">>, M, []),
            case json_to_expr_list(KeysJson) of
                {ok, Keys} -> {ok, {get, Obj, Keys}};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
json_to_expr(#{<<"slice">> := ObjJson} = M) ->
    case json_to_expr(ObjJson) of
        {ok, Obj} ->
            case decode_slice_bounds(M) of
                {ok, S1, S2, S3} -> {ok, {slice, Obj, S1, S2, S3}};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
json_to_expr(#{<<"type">> := TypeStr} = M) ->
    case gdbsp_type:parse_type(TypeStr) of
        {ok, Type} -> decode_value(Type, M);
        {error, _} = E -> E
    end;
json_to_expr(_) ->
    {error, {invalid_expr_json, unrecognized_node}}.

json_call_to_expr(Tag, Name, M) ->
    PosJson = maps:get(<<"args">>, M, []),
    KwJson = maps:get(<<"kwargs">>, M, #{}),
    case json_to_expr_list(PosJson) of
        {ok, PosArgs} ->
            case json_kw_to_expr(KwJson) of
                {ok, KwArgs} ->
                    {ok, {Tag, Name, PosArgs, KwArgs}};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

decode_slice_bounds(M) ->
    try
        {ok, S1} = decode_opt_bound(maps:get(<<"start">>, M, undefined)),
        {ok, S2} = decode_opt_bound(maps:get(<<"stop">>, M, undefined)),
        {ok, S3} = decode_opt_bound(maps:get(<<"step">>, M, undefined)),
        {ok, S1, S2, S3}
    catch
        error:{badmatch, {error, _} = E} -> E
    end.

decode_opt_bound(undefined) -> {ok, undefined};
decode_opt_bound(Json) -> json_to_expr(Json).

json_to_expr_list(List) when is_list(List) ->
    json_to_expr_list(List, []);
json_to_expr_list(_List) ->
    {error, expected_list}.

json_to_expr_list([], Acc) -> {ok, lists:reverse(Acc)};
json_to_expr_list([H | T], Acc) ->
    case json_to_expr(H) of
        {ok, E} -> json_to_expr_list(T, [E | Acc]);
        {error, _} = E -> E
    end.

json_kw_to_expr(Map) when is_map(Map) ->
    json_kw_to_expr(maps:to_list(Map), #{});
json_kw_to_expr(_) ->
    {error, expected_map}.

json_kw_to_expr([], Acc) -> {ok, Acc};
json_kw_to_expr([{K, V} | T], Acc) when is_binary(K) ->
    case json_to_expr(V) of
        {ok, E} -> json_kw_to_expr(T, Acc#{K => E});
        {error, _} = E -> E
    end;
json_kw_to_expr(_, _) ->
    {error, expected_binary_keys}.

%%====================================================================
%% decode_value — type-specific value decoding from new format
%%====================================================================

decode_value({enum, [<<"false">>, <<"true">>]}, #{<<"value">> := <<"true">>}) ->
    {ok, {value, ?BOOL, true}};
decode_value({enum, [<<"false">>, <<"true">>]}, #{<<"value">> := <<"false">>}) ->
    {ok, {value, ?BOOL, false}};
decode_value({enum, [<<"false">>, <<"true">>]}, #{<<"value">> := V}) ->
    {ok, {value, ?BOOL, V}};
decode_value({enum, Names}, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, {enum, Names}, V}};

decode_value(absent, #{<<"value">> := null}) ->
    {ok, {value, absent, absent}};
decode_value({optional, _Inner}, #{<<"value">> := null}) ->
    {ok, {value, absent, absent}};

decode_value(T, #{<<"value">> := V}) when is_binary(V), (
    T =:= i8 orelse T =:= i16 orelse T =:= i32 orelse T =:= i64 orelse
    T =:= u8 orelse T =:= u16 orelse T =:= u32 orelse T =:= u64 orelse
    T =:= integer) ->
    {ok, {value, T, binary_to_integer(V)}};

decode_value(f64, #{<<"value">> := <<"inf">>}) ->
    {ok, {value, f64, infinity}};
decode_value(f64, #{<<"value">> := <<"-inf">>}) ->
    {ok, {value, f64, neg_infinity}};
decode_value(f64, #{<<"value">> := <<"nan">>}) ->
    {ok, {value, f64, nan}};
decode_value(f64, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, f64, binary_to_float_safe(V)}};
decode_value(f32, #{<<"value">> := <<"inf">>}) ->
    {ok, {value, f32, infinity}};
decode_value(f32, #{<<"value">> := <<"-inf">>}) ->
    {ok, {value, f32, neg_infinity}};
decode_value(f32, #{<<"value">> := <<"nan">>}) ->
    {ok, {value, f32, nan}};
decode_value(f32, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, f32, binary_to_float_safe(V)}};

decode_value(numeric, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, numeric, string_to_numeric(V)}};
decode_value({numeric, P, S}, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, {numeric, P, S}, string_to_numeric(V)}};

decode_value(string, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, string, V}};
decode_value({string, E}, #{<<"value">> := V}) when is_binary(V) ->
    {ok, {value, {string, E}, V}};
decode_value(string_with_encoding, #{<<"value">> := #{<<"encoding">> := Enc, <<"value">> := V}}) ->
    {ok, {value, string_with_encoding, {Enc, V}}};

decode_value(bytes, #{<<"value">> := #{<<"encoding">> := Enc, <<"value">> := V}}) ->
    decode_binary(bytes, V, Enc);
decode_value({bytes, N}, #{<<"value">> := #{<<"encoding">> := Enc, <<"value">> := V}}) ->
    decode_binary({bytes, N}, V, Enc);
decode_value(bits, #{<<"value">> := #{<<"encoding">> := Enc, <<"value">> := V}}) ->
    decode_binary(bits, V, Enc);
decode_value({bits, N}, #{<<"value">> := #{<<"encoding">> := Enc, <<"value">> := V}}) ->
    decode_binary({bits, N}, V, Enc);

decode_value(date, #{<<"value">> := #{<<"year">> := Y, <<"month">> := M, <<"day">> := D}}) ->
    {ok, {value, date, {to_int(Y), to_int(M), to_int(D)}}};
decode_value(time, #{<<"value">> := #{<<"hour">> := H, <<"minute">> := Mi,
                                      <<"second">> := S, <<"microsecond">> := Us}}) ->
    {ok, {value, time, {to_int(H), to_int(Mi), to_int(S), to_int(Us)}}};
decode_value(timestamp, #{<<"value">> := #{<<"epoch_microseconds">> := Us}}) ->
    {ok, {value, timestamp, to_int(Us)}};
decode_value(timestamp_with_timezone,
             #{<<"value">> := #{<<"epoch_microseconds">> := Us,
                                <<"offset_seconds">> := Offset} = Inner}) ->
    Zone = maps:get(<<"zone">>, Inner, undefined),
    {ok, {value, timestamp_with_timezone, {to_int(Us), to_int(Offset), Zone}}};
decode_value(interval, #{<<"value">> := #{<<"months">> := Mo, <<"days">> := D,
                                          <<"microseconds">> := Us}}) ->
    {ok, {value, interval, {to_int(Mo), to_int(D), to_int(Us)}}};

decode_value({dynamic, T}, #{<<"value">> := null}) ->
    {ok, {value, {dynamic, T}, absent}};
decode_value({dynamic, _SchemaInner}, #{<<"value">> := #{<<"type">> := InnerType, <<"value">> := InnerVal}}) ->
    case gdbsp_type:parse_type(InnerType) of
        {ok, AT} ->
            case decode_value(AT, #{<<"value">> => InnerVal}) of
                {ok, {value, AT, V}} -> {ok, {value, {dynamic, AT}, V}};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
decode_value(dynamic, #{<<"value">> := null}) ->
    {ok, {value, {dynamic, absent}, absent}};
decode_value(dynamic, #{<<"value">> := #{<<"type">> := InnerType, <<"value">> := InnerVal}}) ->
    case gdbsp_type:parse_type(InnerType) of
        {ok, AT} ->
            case decode_value(AT, #{<<"value">> => InnerVal}) of
                {ok, {value, AT, V}} -> {ok, {value, {dynamic, AT}, V}};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;

decode_value(json, #{<<"value">> := V}) ->
    {ok, gdbsp_value_json:jsx_to_json_node(V)};
decode_value({json, _}, #{<<"value">> := V}) ->
    {ok, gdbsp_value_json:jsx_to_json_node(V)};

decode_value({array, ET, Shape}, #{<<"value">> := List}) when is_list(List) ->
    case decode_value_list(ET, List, []) of
        {ok, Vals} -> {ok, {value, {array, ET, Shape}, Vals}};
        {error, _} = E -> E
    end;
decode_value({map, KT, VT}, #{<<"value">> := Pairs}) when is_list(Pairs) ->
    case decode_map_pairs(KT, VT, Pairs, #{}) of
        {ok, M} -> {ok, {value, {map, KT, VT}, M}};
        {error, _} = E -> E
    end;
decode_value({struct, Fields, Rest}, #{<<"value">> := MapData}) when is_map(MapData) ->
    case decode_struct_fields(Fields, MapData) of
        {ok, M} -> {ok, {value, {struct, Fields, Rest}, M}};
        {error, _} = E -> E
    end;

decode_value(type, #{<<"value">> := V}) ->
    case gdbsp_type:parse_type(V) of
        {ok, T} -> {ok, {value, type, T}};
        {error, _} = E -> E
    end;

decode_value(_Type, _Map) ->
    {error, {invalid_value_json, _Type}}.

%% ── decode helpers ──────────────────────────────────────────────────

decode_value_list(_ET, [], Acc) -> {ok, lists:reverse(Acc)};
decode_value_list(ET, [H | T], Acc) ->
    case decode_value(ET, #{<<"value">> => H}) of
        {ok, {value, _, V}} -> decode_value_list(ET, T, [V | Acc]);
        {error, _} = E -> E
    end.

decode_map_pairs(_KT, _VT, [], Acc) -> {ok, Acc};
decode_map_pairs(KT, VT, [[KJson, VJson] | Rest], Acc) ->
    case {decode_value(KT, #{<<"value">> => KJson}),
          decode_value(VT, #{<<"value">> => VJson})} of
        {{ok, {value, _, K}}, {ok, {value, _, V}}} ->
            decode_map_pairs(KT, VT, Rest, Acc#{K => V});
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E
    end.

decode_struct_fields(Fields, MapData) ->
    maps:fold(fun(Name, FieldType, {ok, Acc}) ->
        case maps:find(Name, MapData) of
            {ok, JsonVal} ->
                case decode_value(FieldType, #{<<"value">> => JsonVal}) of
                    {ok, {value, _, V}} -> {ok, Acc#{Name => V}};
                    {error, _} = E -> E
                end;
            error ->
                {error, {missing_field, Name}}
        end;
    (_Name, _FieldType, {error, _} = E) -> E
    end, {ok, #{}}, Fields).

to_int(V) when is_binary(V) -> binary_to_integer(V);
to_int(V) when is_integer(V) -> V.

binary_to_float_safe(Bin) ->
    try binary_to_float(Bin)
    catch error:badarg ->
        try float(binary_to_integer(Bin))
        catch error:badarg ->
            list_to_float(binary_to_list(Bin))
        end
    end.

string_to_numeric(Bin) ->
    Str = binary_to_list(Bin),
    case string:split(Str, ".") of
        [IntStr] ->
            {list_to_integer(IntStr), 0};
        [IntStr, FracStr] ->
            Scale = length(FracStr),
            FullStr = case IntStr of
                "-0" -> "-" ++ FracStr;
                "0"  -> FracStr;
                _    -> IntStr ++ FracStr
            end,
            {list_to_integer(FullStr), -Scale}
    end.

decode_binary(TypeSpec, V, <<"base64">>) when is_binary(V) ->
    try base64:decode(V) of
        Bin -> {ok, {value, TypeSpec, Bin}}
    catch
        _:_ -> {error, {invalid_base64, V}}
    end;
decode_binary(TypeSpec, V, <<"hex">>) when is_binary(V) ->
    case hex_to_bin(V) of
        {ok, Bin} -> {ok, {value, TypeSpec, Bin}};
        {error, _} = E -> E
    end;
decode_binary(_TypeSpec, _V, Enc) ->
    {error, {unsupported_encoding, Enc}}.

hex_to_bin(Hex) when byte_size(Hex) rem 2 =:= 0 ->
    try << <<(hex_pair(H, L))>> || <<H:8, L:8>> <= Hex >> of
        Bin -> {ok, Bin}
    catch
        _:_ -> {error, invalid_hex}
    end;
hex_to_bin(_Hex) ->
    {error, invalid_hex}.

hex_pair(H, L) -> (hex_digit(H) bsl 4) + hex_digit(L).

hex_digit(C) when C >= $0, C =< $9 -> C - $0;
hex_digit(C) when C >= $a, C =< $f -> C - $a + 10;
hex_digit(C) when C >= $A, C =< $F -> C - $A + 10.

%%====================================================================
%% Validation helpers
%%====================================================================

-spec has_field_nodes(expr()) -> boolean().
has_field_nodes({field, _}) -> true;
has_field_nodes({call, _, PosArgs, KwArgs}) ->
    lists:any(fun has_field_nodes/1, PosArgs) orelse
    maps:fold(fun(_K, V, false) -> has_field_nodes(V);
                 (_K, _V, true) -> true end, false, KwArgs);
has_field_nodes({value, {closure, _, _}, InnerExpr}) -> has_field_nodes(InnerExpr);
has_field_nodes({agg, _, PosArgs, KwArgs}) ->
    lists:any(fun has_field_nodes/1, PosArgs) orelse
    maps:fold(fun(_K, V, false) -> has_field_nodes(V);
                 (_K, _V, true) -> true end, false, KwArgs);
has_field_nodes({get, Obj, Keys}) ->
    has_field_nodes(Obj) orelse lists:any(fun has_field_nodes/1, Keys);
has_field_nodes({slice, Obj, Start, Stop, Step}) ->
    has_field_nodes(Obj) orelse
    has_field_nodes_or_undef(Start) orelse
    has_field_nodes_or_undef(Stop) orelse
    has_field_nodes_or_undef(Step);
has_field_nodes({value, _, _}) -> false.

has_field_nodes_or_undef(undefined) -> false;
has_field_nodes_or_undef(E) -> has_field_nodes(E).

-spec has_blob_calls(expr()) -> boolean().
has_blob_calls({call, <<"storage:blob">>, _, _}) -> true;
has_blob_calls({value, {closure, _, _}, InnerExpr}) -> has_blob_calls(InnerExpr);
has_blob_calls({call, _, PosArgs, KwArgs}) ->
    lists:any(fun has_blob_calls/1, PosArgs) orelse
    maps:fold(fun(_K, V, false) -> has_blob_calls(V);
                 (_K, _V, true) -> true end, false, KwArgs);
has_blob_calls({agg, _, PosArgs, KwArgs}) ->
    lists:any(fun has_blob_calls/1, PosArgs) orelse
    maps:fold(fun(_K, V, false) -> has_blob_calls(V);
                 (_K, _V, true) -> true end, false, KwArgs);
has_blob_calls({get, Obj, Keys}) ->
    has_blob_calls(Obj) orelse lists:any(fun has_blob_calls/1, Keys);
has_blob_calls({slice, Obj, Start, Stop, Step}) ->
    has_blob_calls(Obj) orelse
    has_blob_calls_or_undef(Start) orelse
    has_blob_calls_or_undef(Stop) orelse
    has_blob_calls_or_undef(Step);
has_blob_calls(_) -> false.

has_blob_calls_or_undef(undefined) -> false;
has_blob_calls_or_undef(E) -> has_blob_calls(E).
