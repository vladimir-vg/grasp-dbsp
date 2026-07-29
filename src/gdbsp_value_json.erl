%%%-------------------------------------------------------------------
%%% @doc Canonical value JSON encoding and decoding.
%%%
%%% Single encoding format for JSONL rows and record writes.
%%% See docs/design/grasp-value-type-json-format.md.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_value_json).

-include("gdbsp_type.hrl").

-export([encode_value/2, decode_value/2]).
-export([encode_field/2, decode_field/2]).
-export([encode_typed_value/2]).
-export([encode_row/2, decode_row/2]).
-export([encode_record/2, decode_record/2]).
-export([columns_to_json/1]).
-export([jsx_to_json_node/1, json_node_to_jsx/1]).

%%====================================================================
%% encode_row / decode_row — full row operations
%%====================================================================

-spec encode_row(gdbsp_column_type(), map()) -> map().
encode_row({struct, Fields, _Rest}, Row) when is_map(Row) ->
    maps:fold(fun(Name, SchemaType, Acc) ->
        Val = maps:get(Name, Row),
        Acc#{Name => encode_field(SchemaType, Val)}
    end, #{}, Fields).

-spec decode_row(gdbsp_column_type(), map()) ->
    {ok, map()} | {error, term()}.
decode_row({struct, Fields, _Rest}, Json) when is_map(Json) ->
    decode_row_fields(maps:to_list(Fields), Json, #{}).

decode_row_fields([], _Json, Acc) ->
    {ok, Acc};
decode_row_fields([{Name, SchemaType} | Rest], Json, Acc) ->
    case maps:find(Name, Json) of
        {ok, JsonVal} ->
            case decode_field(SchemaType, JsonVal) of
                {ok, Val} ->
                    decode_row_fields(Rest, Json, Acc#{Name => Val});
                {error, _} = Err -> Err
            end;
        error ->
            {error, {missing_column, Name}}
    end.

-spec columns_to_json(gdbsp_column_type()) -> map().
columns_to_json({struct, Fields, _Rest}) ->
    maps:map(fun(_Name, Type) ->
        gdbsp_type:type_to_json(Type)
    end, Fields).

%%====================================================================
%% encode_record / decode_record — full record to/from JSON binary
%%====================================================================

-spec encode_record(gdbsp_column_type(), [term()]) -> binary().
encode_record(_SchemaType, [Row, Weight, Meta]) ->
    jsx:encode([Row, Weight, Meta]).

-spec decode_record(gdbsp_column_type(), binary()) -> [term()].
decode_record(_SchemaType, Binary) ->
    jsx:decode(Binary, [return_maps]).

%%====================================================================
%% encode_field — dispatches optional / dynamic / concrete
%%====================================================================

-spec encode_field(gdbsp_column_type(), term()) -> jsx:json_term().
encode_field({optional, _}, absent) ->
    null;
encode_field({optional, json}, {value, Node}) ->
    #{<<"value">> => json_node_to_jsx(Node)};
encode_field({optional, {closure, _, _} = C}, {value, Val}) ->
    #{<<"value">> => encode_value(C, Val)};
encode_field({optional, Inner}, {value, Val}) ->
    encode_value(Inner, Val);
encode_field({dynamic, _}, {value, {dynamic, T}, RawVal}) ->
    encode_typed_value(T, RawVal);
encode_field(dynamic, {value, {dynamic, T}, RawVal}) ->
    encode_typed_value(T, RawVal);
encode_field({json, _}, Node) ->
    json_node_to_jsx(Node);
encode_field(json, Node) ->
    json_node_to_jsx(Node);
encode_field(SchemaType, Val) ->
    encode_value(SchemaType, strip_wrappers(Val)).

strip_wrappers({value, _, {value, _, _} = Inner}) -> strip_wrappers(Inner);
strip_wrappers({value, _, RawVal}) -> RawVal;
strip_wrappers(absent) -> absent;
strip_wrappers(Val) -> Val.

%%====================================================================
%% decode_field — dispatches optional / dynamic / concrete
%%====================================================================

-spec decode_field(gdbsp_column_type(), jsx:json_term()) ->
    {ok, term()} | {error, term()}.
decode_field({optional, _}, null) ->
    {ok, absent};
decode_field({optional, json}, #{<<"value">> := Val}) ->
    {ok, {value, jsx_to_json_node(Val)}};
decode_field({optional, {closure, _, _} = C}, #{<<"value">> := Val}) ->
    {ok, Decoded} = decode_value(C, Val),
    {ok, {value, Decoded}};
decode_field({optional, Inner}, Val) ->
    case decode_field(Inner, Val) of
        {ok, Decoded} -> {ok, {value, Decoded}};
        {error, _} = Err -> Err
    end;
decode_field({dynamic, _}, null) ->
    {ok, absent};
decode_field({dynamic, _}, #{<<"type">> := TypeJson, <<"value">> := ValJson}) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, ActualType} ->
            case decode_value(ActualType, ValJson) of
                {ok, Val} -> {ok, {value, {dynamic, ActualType}, Val}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end;
decode_field(dynamic, null) ->
    {ok, absent};
decode_field(dynamic, #{<<"type">> := TypeJson, <<"value">> := ValJson}) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, ActualType} ->
            case decode_value(ActualType, ValJson) of
                {ok, Val} -> {ok, {value, {dynamic, ActualType}, Val}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end;
decode_field({json, _}, Val) ->
    {ok, jsx_to_json_node(Val)};
decode_field(json, Val) ->
    {ok, jsx_to_json_node(Val)};
decode_field(Type, Val) ->
    decode_value(Type, Val).

%%====================================================================
%% encode_typed_value — {"type": T, "value": V}
%%====================================================================

-spec encode_typed_value(gdbsp_column_type(), term()) -> map().
encode_typed_value(Type, RawVal) ->
    #{<<"type">> => gdbsp_type:type_to_json(Type),
      <<"value">> => encode_value(Type, RawVal)}.

%%====================================================================
%% encode_value — type-specific encoding (no type wrapper)
%%====================================================================

-spec encode_value(gdbsp_column_type(), term()) -> jsx:json_term().

encode_value({enum, [<<"false">>, <<"true">>]}, true) -> <<"true">>;
encode_value({enum, [<<"false">>, <<"true">>]}, false) -> <<"false">>;
encode_value({enum, _}, Name) when is_binary(Name) -> Name;
encode_value({enum, _}, Name) when is_atom(Name) -> atom_to_binary(Name, utf8);

encode_value(absent, _) -> null;

encode_value(T, N) when is_integer(N), (
    T =:= i8 orelse T =:= i16 orelse T =:= i32 orelse T =:= i64 orelse
    T =:= u8 orelse T =:= u16 orelse T =:= u32 orelse T =:= u64 orelse
    T =:= integer) -> integer_to_binary(N);

encode_value(f64, infinity)     -> <<"inf">>;
encode_value(f64, neg_infinity) -> <<"-inf">>;
encode_value(f64, nan)          -> <<"nan">>;
encode_value(f64, V) when is_number(V) -> float_to_binary(float(V), [short]);
encode_value(f32, infinity)     -> <<"inf">>;
encode_value(f32, neg_infinity) -> <<"-inf">>;
encode_value(f32, nan)          -> <<"nan">>;
encode_value(f32, V) when is_number(V) -> float_to_binary(float(V), [short]);

encode_value(numeric, {Num, Scale}) -> numeric_to_string(Num, Scale);
encode_value({numeric, _, _}, {Num, Scale}) -> numeric_to_string(Num, Scale);

encode_value(string, Bin) when is_binary(Bin) -> Bin;
encode_value({string, _}, Bin) when is_binary(Bin) -> Bin;
encode_value(string_with_encoding, {Enc, Bin}) when is_binary(Bin) ->
    #{<<"encoding">> => Enc, <<"value">> => Bin};

encode_value(bytes, Bin) when is_binary(Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};
encode_value({bytes, _}, Bin) when is_binary(Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};
encode_value(bits, Bin) when is_binary(Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};
encode_value({bits, _}, Bin) when is_binary(Bin) ->
    #{<<"encoding">> => <<"base64">>, <<"value">> => base64:encode(Bin)};

encode_value(date, {Y, M, D}) ->
    #{<<"year">> => i2b(Y), <<"month">> => i2b(M), <<"day">> => i2b(D)};
encode_value(time, {H, Mi, S, Us}) ->
    #{<<"hour">> => i2b(H), <<"minute">> => i2b(Mi),
      <<"second">> => i2b(S), <<"microsecond">> => i2b(Us)};
encode_value(timestamp, Us) when is_integer(Us) ->
    #{<<"epoch_microseconds">> => i2b(Us)};
encode_value(timestamp_with_timezone, {Us, Offset, Zone}) ->
    M = #{<<"epoch_microseconds">> => i2b(Us),
          <<"offset_seconds">> => i2b(Offset)},
    case Zone of
        undefined -> M;
        _ -> M#{<<"zone">> => Zone}
    end;
encode_value(interval, {Months, Days, Us}) ->
    #{<<"months">> => i2b(Months), <<"days">> => i2b(Days),
      <<"microseconds">> => i2b(Us)};

%% A json payload may arrive as a full node (when wrapped by dynamic) or as
%% the raw top payload of a json node.
encode_value({json, _}, {value, {json, _}, _} = Node) -> json_node_to_jsx(Node);
encode_value({json, T}, Payload) -> json_payload_to_jsx(T, Payload);

encode_value({dynamic, _}, absent) -> null;
encode_value({dynamic, T}, RawVal) ->
    encode_typed_value(T, RawVal);
encode_value(dynamic, {value, {dynamic, T}, RawVal}) ->
    encode_typed_value(T, RawVal);
encode_value(dynamic, absent) -> null;

encode_value({closure, _, _}, null) -> null;
encode_value({closure, _, _}, Expr) ->
    gdbsp_expr:expr_to_json(Expr);

encode_value({array, ET, _}, List) when is_list(List) ->
    [encode_field(ET, El) || El <- List];
encode_value({map, KT, VT}, M) when is_map(M) ->
    [[encode_value(KT, strip_wrappers(K)), encode_field(VT, V)]
     || {K, V} <- maps:to_list(M)];
encode_value({struct, Fields, _Rest}, M) when is_map(M) ->
    maps:fold(fun(Name, FieldType, Acc) ->
        Val = maps:get(Name, M),
        Acc#{Name => encode_field(FieldType, Val)}
    end, #{}, Fields).

%%====================================================================
%% decode_value — type-specific decoding (no type wrapper)
%%====================================================================

-spec decode_value(gdbsp_column_type(), jsx:json_term()) ->
    {ok, term()} | {error, term()}.

decode_value({enum, [<<"false">>, <<"true">>]}, <<"true">>) -> {ok, true};
decode_value({enum, [<<"false">>, <<"true">>]}, <<"false">>) -> {ok, false};
decode_value({enum, Names}, V) when is_binary(V) ->
    case lists:member(V, Names) of
        true -> {ok, V};
        false -> {error, {invalid_enum_value, V, Names}}
    end;

decode_value(absent, null) -> {ok, absent};

decode_value(T, V) when is_binary(V), (
    T =:= i8 orelse T =:= i16 orelse T =:= i32 orelse T =:= i64 orelse
    T =:= u8 orelse T =:= u16 orelse T =:= u32 orelse T =:= u64 orelse
    T =:= integer) ->
    try {ok, binary_to_integer(V)}
    catch _:_ -> {error, {invalid_integer, T, V}}
    end;

decode_value(f64, <<"inf">>) -> {ok, infinity};
decode_value(f64, <<"-inf">>) -> {ok, neg_infinity};
decode_value(f64, <<"nan">>) -> {ok, nan};
decode_value(f64, V) when is_binary(V) -> parse_float_binary(V);
decode_value(f32, <<"inf">>) -> {ok, infinity};
decode_value(f32, <<"-inf">>) -> {ok, neg_infinity};
decode_value(f32, <<"nan">>) -> {ok, nan};
decode_value(f32, V) when is_binary(V) -> parse_float_binary(V);

decode_value(numeric, V) when is_binary(V) -> string_to_numeric(V);
decode_value({numeric, _, _}, V) when is_binary(V) -> string_to_numeric(V);

decode_value(string, V) when is_binary(V) -> {ok, V};
decode_value({string, _}, V) when is_binary(V) -> {ok, V};
decode_value(string_with_encoding, #{<<"encoding">> := Enc, <<"value">> := V})
  when is_binary(V) ->
    {ok, {Enc, V}};

decode_value(bytes, #{<<"encoding">> := <<"base64">>, <<"value">> := V}) ->
    decode_base64(V);
decode_value({bytes, _}, #{<<"encoding">> := <<"base64">>, <<"value">> := V}) ->
    decode_base64(V);
decode_value(bits, #{<<"encoding">> := <<"base64">>, <<"value">> := V}) ->
    decode_base64(V);
decode_value({bits, _}, #{<<"encoding">> := <<"base64">>, <<"value">> := V}) ->
    decode_base64(V);

decode_value(date, #{<<"year">> := Y, <<"month">> := M, <<"day">> := D})
  when is_binary(Y), is_binary(M), is_binary(D) ->
    {ok, {b2i(Y), b2i(M), b2i(D)}};
decode_value(time, #{<<"hour">> := H, <<"minute">> := Mi,
                     <<"second">> := S, <<"microsecond">> := Us})
  when is_binary(H), is_binary(Mi), is_binary(S), is_binary(Us) ->
    {ok, {b2i(H), b2i(Mi), b2i(S), b2i(Us)}};
decode_value(timestamp, #{<<"epoch_microseconds">> := Us}) when is_binary(Us) ->
    {ok, b2i(Us)};
decode_value(timestamp_with_timezone,
             #{<<"epoch_microseconds">> := Us, <<"offset_seconds">> := Offset} = M)
  when is_binary(Us), is_binary(Offset) ->
    Zone = maps:get(<<"zone">>, M, undefined),
    {ok, {b2i(Us), b2i(Offset), Zone}};
decode_value(interval, #{<<"months">> := Mo, <<"days">> := D,
                          <<"microseconds">> := Us})
  when is_binary(Mo), is_binary(D), is_binary(Us) ->
    {ok, {b2i(Mo), b2i(D), b2i(Us)}};

decode_value(json, V) -> {ok, jsx_to_json_node(V)};
decode_value({json, _}, V) -> {ok, jsx_to_json_node(V)};

decode_value(dynamic, null) -> {ok, absent};
decode_value({dynamic, _}, null) -> {ok, absent};
decode_value(dynamic, #{<<"type">> := TypeJson, <<"value">> := ValJson}) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, ActualType} ->
            case decode_value(ActualType, ValJson) of
                {ok, Val} -> {ok, {value, {dynamic, ActualType}, Val}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end;
decode_value({dynamic, _}, #{<<"type">> := TypeJson, <<"value">> := ValJson}) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, ActualType} ->
            case decode_value(ActualType, ValJson) of
                {ok, Val} -> {ok, {value, {dynamic, ActualType}, Val}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end;

decode_value({closure, _, _}, null) -> {ok, null};
decode_value({closure, _, _}, Json) ->
    gdbsp_expr:json_to_expr(Json);

decode_value({array, ET, _}, List) when is_list(List) ->
    decode_list(ET, List, []);
decode_value({map, KT, VT}, List) when is_list(List) ->
    decode_map_pairs(KT, VT, List, #{});
decode_value({struct, Fields, _Rest}, M) when is_map(M) ->
    decode_struct(maps:to_list(Fields), M, #{});

decode_value(Type, Val) ->
    {error, {type_mismatch, Type, Val}}.

%%====================================================================
%% json value tree <-> native jsx conversion
%%
%% A json value is a recursive typed value: every node carries a
%% {json, ConcreteType} tag (see grasp-value-type-json-format.md §3.8).
%%   number  -> {value, {json, f64},                  Float}
%%   string  -> {value, {json, string},               Bin}
%%   bool    -> {value, {json, {enum,[false,true]}},   true|false}
%%   null    -> {value, {json, {enum,[<<"null">>]}},   <<"null">>}
%%   array   -> {value, {json, {array, json, varsize}}, [Node, ...]}
%%   object  -> {value, {json, {map, string, json}},    #{Bin => Node}}
%% All JSON numbers normalise to f64.
%%====================================================================

-spec jsx_to_json_node(jsx:json_term()) -> value().
jsx_to_json_node(N) when is_number(N) ->
    {value, {json, f64}, float(N)};
jsx_to_json_node(true) ->
    {value, {json, ?BOOL}, true};
jsx_to_json_node(false) ->
    {value, {json, ?BOOL}, false};
jsx_to_json_node(null) ->
    {value, {json, {enum, [<<"null">>]}}, <<"null">>};
jsx_to_json_node(B) when is_binary(B) ->
    {value, {json, string}, B};
jsx_to_json_node(L) when is_list(L) ->
    {value, {json, {array, json, varsize}}, [jsx_to_json_node(E) || E <- L]};
jsx_to_json_node(M) when is_map(M) ->
    {value, {json, {map, string, json}},
     maps:map(fun(_K, V) -> jsx_to_json_node(V) end, M)}.

-spec json_node_to_jsx(value()) -> jsx:json_term().
json_node_to_jsx({value, {json, T}, V}) ->
    json_payload_to_jsx(T, V).

json_payload_to_jsx(f64, F) -> F;
json_payload_to_jsx(string, B) -> B;
json_payload_to_jsx({enum, [<<"false">>, <<"true">>]}, B) -> B;
json_payload_to_jsx({enum, [<<"null">>]}, _) -> null;
json_payload_to_jsx({array, json, _}, L) ->
    [json_node_to_jsx(C) || C <- L];
json_payload_to_jsx({map, string, json}, M) ->
    maps:map(fun(_K, C) -> json_node_to_jsx(C) end, M).

%%====================================================================
%% Internal helpers
%%====================================================================

i2b(N) -> integer_to_binary(N).
b2i(B) -> binary_to_integer(B).

parse_float_binary(Bin) ->
    try {ok, binary_to_float(Bin)}
    catch _:_ ->
        try {ok, float(binary_to_integer(Bin))}
        catch _:_ -> {error, {invalid_float, Bin}}
        end
    end.

numeric_to_string(Coeff, 0) ->
    integer_to_binary(Coeff);
numeric_to_string(Coeff, Scale) when Scale > 0 ->
    {Sign, Abs} = case Coeff < 0 of
        true -> {<<"-">>, -Coeff};
        false -> {<<>>, Coeff}
    end,
    AbsStr = integer_to_list(Abs),
    Len = length(AbsStr),
    Padded = case Len =< Scale of
        true -> lists:duplicate(Scale - Len + 1, $0) ++ AbsStr;
        false -> AbsStr
    end,
    PaddedLen = length(Padded),
    IntPart = lists:sublist(Padded, PaddedLen - Scale),
    DecPart = lists:sublist(Padded, PaddedLen - Scale + 1, Scale),
    iolist_to_binary([Sign, IntPart, ".", DecPart]).

string_to_numeric(Bin) ->
    case binary:split(Bin, <<".">>) of
        [IntBin] ->
            {ok, {binary_to_integer(IntBin), 0}};
        [IntBin, DecBin] ->
            Scale = byte_size(DecBin),
            Sign = case IntBin of
                <<"-", Rest/binary>> -> {negative, Rest};
                _ -> {positive, IntBin}
            end,
            {Polarity, AbsIntBin} = Sign,
            AbsCoeff = binary_to_integer(<<AbsIntBin/binary, DecBin/binary>>),
            Coeff = case Polarity of
                negative -> -AbsCoeff;
                positive -> AbsCoeff
            end,
            {ok, {Coeff, Scale}}
    end.

decode_base64(V) when is_binary(V) ->
    try base64:decode(V) of
        Bin -> {ok, Bin}
    catch
        _:_ -> {error, {invalid_base64, V}}
    end.

decode_list(_ET, [], Acc) ->
    {ok, lists:reverse(Acc)};
decode_list(ET, [H | T], Acc) ->
    case decode_field(ET, H) of
        {ok, Val} -> decode_list(ET, T, [Val | Acc]);
        {error, _} = Err -> Err
    end.

decode_map_pairs(_KT, _VT, [], Acc) ->
    {ok, Acc};
decode_map_pairs(KT, VT, [[K, V] | Rest], Acc) ->
    case decode_value(KT, K) of
        {ok, DecodedKey} ->
            case decode_field(VT, V) of
                {ok, DecodedVal} ->
                    decode_map_pairs(KT, VT, Rest, Acc#{DecodedKey => DecodedVal});
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

decode_struct([], _M, Acc) ->
    {ok, Acc};
decode_struct([{Name, FieldType} | Rest], M, Acc) ->
    case maps:find(Name, M) of
        {ok, JsonVal} ->
            case decode_field(FieldType, JsonVal) of
                {ok, Val} -> decode_struct(Rest, M, Acc#{Name => Val});
                {error, _} = Err -> Err
            end;
        error ->
            {error, {missing_field, Name}}
    end.
