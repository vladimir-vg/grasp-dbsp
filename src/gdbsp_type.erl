%%%-------------------------------------------------------------------
%%% @doc Unified type module for gdbsp_column_type().
%%%
%%% Schema parsing (from JSON), canonical text, hashing,
%%% assignability, widening, runtime filter detection.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_type).

-include("gdbsp_type.hrl").

%% ── Schema parsing ──────────────────────────────────────────────────
-export([parse_columns/1, parse_type/1]).

%% ── JSON type representation ────────────────────────────────────────
-export([type_to_json/1]).

%% ── Canonical text & hash ───────────────────────────────────────────
-export([canonical_text/1, parse_canonical_text/1, hash/1]).

%% ── Normalization ───────────────────────────────────────────────────
-export([collapse/1]).

%% ── Type algebra ────────────────────────────────────────────────────
-export([is_int_widening/2]).
-export([is_assignable/2, requires_runtime_filter/2, widen/2]).
-export([contains_closure_or_any/1]).

%%====================================================================
%% Schema parsing (JSON → gdbsp_column_type())
%%====================================================================

-spec parse_columns(map()) -> {ok, gdbsp_column_type()} | {error, term()}.
parse_columns(Columns) when is_map(Columns) ->
    case parse_columns_acc(Columns) of
        {ok, Fields} ->
            {ok, {struct, Fields, exact}};
        {error, _} = Err -> Err
    end.

parse_columns_acc(Columns) when is_map(Columns) ->
    maps:fold(fun(K, V, Acc) ->
        case Acc of
            {ok, Fields} ->
                case parse_type_grasp(V) of
                    {ok, T} -> {ok, Fields#{to_binary(K) => T}};
                    {error, _} = Err -> Err
                end;
            {error, _} -> Acc
        end
    end, {ok, #{}}, Columns).

-spec parse_type(term()) -> {ok, gdbsp_column_type()} | {error, term()}.
parse_type(Term) -> parse_type_grasp(Term).

parse_type_grasp(<<"boolean">>) -> {ok, {enum, [<<"false">>, <<"true">>]}};
parse_type_grasp("boolean") -> {ok, {enum, [<<"false">>, <<"true">>]}};
parse_type_grasp(<<"i8">>) -> {ok, i8};
parse_type_grasp("i8") -> {ok, i8};
parse_type_grasp(<<"i16">>) -> {ok, i16};
parse_type_grasp("i16") -> {ok, i16};
parse_type_grasp(<<"i32">>) -> {ok, i32};
parse_type_grasp("i32") -> {ok, i32};
parse_type_grasp(<<"i64">>) -> {ok, i64};
parse_type_grasp("i64") -> {ok, i64};
parse_type_grasp(<<"u8">>) -> {ok, u8};
parse_type_grasp("u8") -> {ok, u8};
parse_type_grasp(<<"u16">>) -> {ok, u16};
parse_type_grasp("u16") -> {ok, u16};
parse_type_grasp(<<"u32">>) -> {ok, u32};
parse_type_grasp("u32") -> {ok, u32};
parse_type_grasp(<<"u64">>) -> {ok, u64};
parse_type_grasp("u64") -> {ok, u64};
parse_type_grasp(<<"integer">>) -> {ok, integer};
parse_type_grasp("integer") -> {ok, integer};
parse_type_grasp(<<"f32">>) -> {ok, f32};
parse_type_grasp("f32") -> {ok, f32};
parse_type_grasp(<<"f64">>) -> {ok, f64};
parse_type_grasp("f64") -> {ok, f64};
parse_type_grasp(<<"numeric">>) -> {ok, numeric};
parse_type_grasp("numeric") -> {ok, numeric};
parse_type_grasp(<<"string">>) -> {ok, string};
parse_type_grasp("string") -> {ok, string};
parse_type_grasp(<<"string_with_encoding">>) -> {ok, string_with_encoding};
parse_type_grasp("string_with_encoding") -> {ok, string_with_encoding};
parse_type_grasp(<<"bytes">>) -> {ok, bytes};
parse_type_grasp("bytes") -> {ok, bytes};
parse_type_grasp(<<"bits">>) -> {ok, bits};
parse_type_grasp("bits") -> {ok, bits};
parse_type_grasp(<<"date">>) -> {ok, date};
parse_type_grasp("date") -> {ok, date};
parse_type_grasp(<<"time">>) -> {ok, time};
parse_type_grasp("time") -> {ok, time};
parse_type_grasp(<<"timestamp">>) -> {ok, timestamp};
parse_type_grasp("timestamp") -> {ok, timestamp};
parse_type_grasp(<<"timestamp_with_timezone">>) -> {ok, timestamp_with_timezone};
parse_type_grasp("timestamp_with_timezone") -> {ok, timestamp_with_timezone};
parse_type_grasp(<<"interval">>) -> {ok, interval};
parse_type_grasp("interval") -> {ok, interval};
parse_type_grasp(<<"json">>) -> {ok, json};
parse_type_grasp("json") -> {ok, json};
parse_type_grasp(<<"dynamic">>) -> {ok, dynamic};
parse_type_grasp("dynamic") -> {ok, dynamic};
parse_type_grasp(<<"null">>) -> {ok, absent};
parse_type_grasp(<<"absent">>) -> {ok, absent};
parse_type_grasp("null") -> {ok, absent};
parse_type_grasp("absent") -> {ok, absent};
parse_type_grasp(<<"type">>) -> {ok, type};
parse_type_grasp(#{<<"enum">> := List}) when is_list(List) ->
    Names = lists:usort([to_binary(V) || V <- List]),
    case Names of
        [] -> {error, empty_enum};
        _ -> {ok, {enum, Names}}
    end;
parse_type_grasp(#{<<"optional">> := Inner}) ->
    case parse_type_grasp(Inner) of
        {ok, T} -> {ok, {optional, T}};
        Error -> Error
    end;
parse_type_grasp(#{<<"json">> := Inner}) ->
    case parse_type_grasp(Inner) of
        {ok, T} -> {ok, {json, T}};
        Error -> Error
    end;
parse_type_grasp(#{<<"dynamic">> := Inner}) ->
    case parse_type_grasp(Inner) of
        {ok, T} -> {ok, {dynamic, T}};
        Error -> Error
    end;
parse_type_grasp(#{<<"closure">> := #{<<"return">> := RetType} = Obj}) ->
    case parse_closure_params(Obj) of
        {ok, Params} ->
            case parse_type_grasp(RetType) of
                {ok, RT} -> {ok, {closure, Params, RT}};
                Error -> Error
            end;
        Error -> Error
    end;
parse_type_grasp(#{<<"bytes">> := #{<<"size">> := N}}) when is_integer(N), N >= 0 ->
    {ok, {bytes, N}};
parse_type_grasp(#{<<"bits">> := #{<<"size">> := N}}) when is_integer(N), N >= 0 ->
    {ok, {bits, N}};
parse_type_grasp(#{<<"numeric">> := #{<<"precision">> := P, <<"scale">> := S}})
  when is_integer(P), is_integer(S), P >= 0, S >= 0, S =< P ->
    {ok, {numeric, P, S}};
parse_type_grasp(#{<<"string">> := #{<<"encoding">> := Enc}}) when is_binary(Enc) ->
    {ok, {string, Enc}};
parse_type_grasp(#{<<"array">> := #{<<"element">> := Elem} = Spec}) ->
    case parse_type_grasp(Elem) of
        {ok, ET} ->
            case Spec of
                #{<<"shape">> := Shape} when is_list(Shape) ->
                    {ok, {array, ET, Shape}};
                #{<<"size">> := N} when is_integer(N), N >= 0 ->
                    {ok, {array, ET, N}};
                _ ->
                    {ok, {array, ET, varsize}}
            end;
        Error -> Error
    end;
parse_type_grasp(#{<<"array">> := Elem}) when is_map(Elem) orelse is_binary(Elem) ->
    case parse_type_grasp(Elem) of
        {ok, ET} -> {ok, {array, ET, varsize}};
        Error -> Error
    end;
parse_type_grasp(#{<<"map">> := #{<<"key">> := K, <<"value">> := V}}) ->
    case {parse_type_grasp(K), parse_type_grasp(V)} of
        {{ok, KT}, {ok, VT}} -> {ok, {map, KT, VT}};
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E
    end;
parse_type_grasp(#{<<"struct">> := <<"**">>}) ->
    {ok, {struct, #{}, wildcard}};
parse_type_grasp(#{<<"struct">> := Fields}) when is_map(Fields) ->
    parse_columns(Fields);
parse_type_grasp(_Other) ->
    {error, {unrecognized_type, _Other}}.

to_binary(S) when is_binary(S) -> S;
to_binary(S) when is_list(S) -> list_to_binary(S);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).

%% ── parse_closure_params ────────────────────────────────────────────

-spec parse_type_grasp(binary() | list() | map()) ->
    {ok, gdbsp_column_type()} | {error, term()}.

parse_closure_params(#{<<"params">> := ParamsMap}) when is_map(ParamsMap) ->
    maps:fold(fun(_Name, _Type, {error, _} = E) -> E;
                 (Name, Type, {ok, Acc}) ->
                     case parse_type_grasp(Type) of
                         {ok, T} -> {ok, [{to_binary(Name), T} | Acc]};
                         Error -> Error
                     end
              end, {ok, []}, ParamsMap);
parse_closure_params(_) -> {ok, []}.

%%====================================================================
%% type_to_json — gdbsp_column_type() → JSON type representation
%%====================================================================

-spec type_to_json(gdbsp_column_type()) -> jsx:json_term().
type_to_json(?BOOL) -> <<"boolean">>;
type_to_json({enum, Names}) -> type_to_json_enum(lists:sort(Names));
type_to_json(i8) -> <<"i8">>;
type_to_json(i16) -> <<"i16">>;
type_to_json(i32) -> <<"i32">>;
type_to_json(i64) -> <<"i64">>;
type_to_json(u8) -> <<"u8">>;
type_to_json(u16) -> <<"u16">>;
type_to_json(u32) -> <<"u32">>;
type_to_json(u64) -> <<"u64">>;
type_to_json(integer) -> <<"integer">>;
type_to_json(f32) -> <<"f32">>;
type_to_json(f64) -> <<"f64">>;
type_to_json(numeric) -> <<"numeric">>;
type_to_json(string) -> <<"string">>;
type_to_json(string_with_encoding) -> <<"string_with_encoding">>;
type_to_json(bytes) -> <<"bytes">>;
type_to_json(bits) -> <<"bits">>;
type_to_json(date) -> <<"date">>;
type_to_json(time) -> <<"time">>;
type_to_json(timestamp) -> <<"timestamp">>;
type_to_json(timestamp_with_timezone) -> <<"timestamp_with_timezone">>;
type_to_json(interval) -> <<"interval">>;
type_to_json(json) -> <<"json">>;
type_to_json(dynamic) -> <<"dynamic">>;
type_to_json({json, T}) -> #{<<"json">> => type_to_json(T)};
type_to_json({dynamic, T}) -> #{<<"dynamic">> => type_to_json(T)};
type_to_json(absent) -> <<"absent">>;
type_to_json(type) -> <<"type">>;
type_to_json({optional, T}) ->
    #{<<"optional">> => type_to_json(T)};
type_to_json({closure, [], T}) ->
    #{<<"closure">> => #{<<"return">> => type_to_json(T)}};
type_to_json({closure, Params, T}) ->
    ParamsMap = maps:from_list(
        [{Name, type_to_json(PT)} || {Name, PT} <- Params]),
    #{<<"closure">> => #{<<"params">> => ParamsMap,
                         <<"return">> => type_to_json(T)}};
type_to_json({numeric, P, S}) ->
    #{<<"numeric">> => #{<<"precision">> => P, <<"scale">> => S}};
type_to_json({bytes, N}) ->
    #{<<"bytes">> => #{<<"size">> => N}};
type_to_json({bits, N}) ->
    #{<<"bits">> => #{<<"size">> => N}};
type_to_json({string, E}) ->
    #{<<"string">> => #{<<"encoding">> => E}};
type_to_json({array, T, varsize}) ->
    #{<<"array">> => type_to_json(T)};
type_to_json({array, T, N}) when is_integer(N) ->
    #{<<"array">> => #{<<"element">> => type_to_json(T), <<"size">> => N}};
type_to_json({array, T, Dims}) when is_list(Dims) ->
    #{<<"array">> => #{<<"element">> => type_to_json(T), <<"shape">> => Dims}};
type_to_json({map, K, V}) ->
    #{<<"map">> => #{<<"key">> => type_to_json(K),
                     <<"value">> => type_to_json(V)}};
type_to_json({struct, Fields, wildcard}) when map_size(Fields) =:= 0 ->
    #{<<"struct">> => <<"**">>};
type_to_json({struct, Fields, _Rest}) ->
    #{<<"struct">> => maps:map(fun(_F, T) -> type_to_json(T) end, Fields)}.

type_to_json_enum([<<"false">>, <<"true">>]) -> <<"boolean">>;
type_to_json_enum(Names) -> #{<<"enum">> => Names}.

%%====================================================================
%% Canonical text
%%====================================================================

-spec canonical_text(gdbsp_column_type()) -> binary().
canonical_text(Type) ->
    canonical_text_inner(collapse(Type)).

canonical_text_inner(?BOOL) -> <<"boolean">>;
canonical_text_inner(i8)  -> <<"i8">>;
canonical_text_inner(i16) -> <<"i16">>;
canonical_text_inner(i32) -> <<"i32">>;
canonical_text_inner(i64) -> <<"i64">>;
canonical_text_inner(u8)  -> <<"u8">>;
canonical_text_inner(u16) -> <<"u16">>;
canonical_text_inner(u32) -> <<"u32">>;
canonical_text_inner(u64) -> <<"u64">>;
canonical_text_inner(integer) -> <<"integer">>;
canonical_text_inner(f32) -> <<"f32">>;
canonical_text_inner(f64) -> <<"f64">>;
canonical_text_inner(numeric) -> <<"numeric">>;
canonical_text_inner(string) -> <<"string">>;
canonical_text_inner(string_with_encoding) -> <<"string_with_encoding">>;
canonical_text_inner(bytes) -> <<"bytes">>;
canonical_text_inner(bits) -> <<"bits">>;
canonical_text_inner(date) -> <<"date">>;
canonical_text_inner(time) -> <<"time">>;
canonical_text_inner(timestamp) -> <<"timestamp">>;
canonical_text_inner(timestamp_with_timezone) -> <<"timestamp_with_timezone">>;
canonical_text_inner(interval) -> <<"interval">>;
canonical_text_inner(json) -> <<"json">>;
canonical_text_inner({json, T}) -> <<"json(", (canonical_text_inner(T))/binary, ")">>;
canonical_text_inner(dynamic) -> <<"dynamic">>;
canonical_text_inner({dynamic, T}) -> <<"dynamic(", (canonical_text_inner(T))/binary, ")">>;
canonical_text_inner(absent) -> <<"absent">>;
canonical_text_inner(type) -> <<"type">>;
canonical_text_inner({type_var, Name}) -> <<"'", (atom_to_binary(Name))/binary, "'">>;
canonical_text_inner({numeric, P, S}) ->
    <<"numeric(", (integer_to_binary(P))/binary, ",", (integer_to_binary(S))/binary, ")">>;
canonical_text_inner({string, E}) ->
    <<"string(\"", E/binary, "\")">>;
canonical_text_inner({enum, [<<"false">>, <<"true">>]}) -> <<"boolean">>;
canonical_text_inner({enum, Names}) ->
    Sorted = lists:sort(Names),
    Parts = [<<"\"", (escape_field_name(N))/binary, "\"">> || N <- Sorted],
    <<"enum(", (iolist_to_binary(lists:join(",", Parts)))/binary, ")">>;
canonical_text_inner({bytes, N}) ->
    <<"bytes(", (integer_to_binary(N))/binary, ")">>;
canonical_text_inner({bits, N}) ->
    <<"bits(", (integer_to_binary(N))/binary, ")">>;
canonical_text_inner({optional, T}) ->
    <<"optional(", (canonical_text_inner(T))/binary, ")">>;
canonical_text_inner({closure, [], T}) ->
    <<"closure(->", (canonical_text_inner(T))/binary, ")">>;
canonical_text_inner({closure, Params, T}) ->
    Sorted = lists:sort(Params),
    Parts = [<<"\"", Name/binary, "\":", (canonical_text_inner(PT))/binary>>
             || {Name, PT} <- Sorted],
    Inside = lists:foldl(fun(P, <<>>) -> P;
                            (P, Acc) -> <<Acc/binary, ",", P/binary>>
                         end, <<>>, Parts),
    <<"closure(", Inside/binary, "->", (canonical_text_inner(T))/binary, ")">>;
canonical_text_inner({array, T, varsize}) ->
    <<"array(", (canonical_text_inner(T))/binary, ")">>;
canonical_text_inner({array, T, N}) when is_integer(N) ->
    <<"array(", (canonical_text_inner(T))/binary, ",", (integer_to_binary(N))/binary, ")">>;
canonical_text_inner({array, T, Dims}) when is_list(Dims) ->
    DimParts = [integer_to_binary(D) || D <- Dims],
    <<"array(", (canonical_text_inner(T))/binary, ",",
      (iolist_to_binary(lists:join(",", DimParts)))/binary, ")">>;
canonical_text_inner({map, K, V}) ->
    <<"map(", (canonical_text_inner(K))/binary, ",", (canonical_text_inner(V))/binary, ")">>;
canonical_text_inner({struct, Fields, Rest}) ->
    SortedKeys = lists:sort(maps:keys(Fields)),
    FieldParts = [<<"\"", (escape_field_name(F))/binary, "\":",
                    (canonical_text_inner(maps:get(F, Fields)))/binary>> || F <- SortedKeys],
    Inner = iolist_to_binary(lists:join(",", FieldParts)),
    RestPart = struct_rest_text(Rest, Inner),
    <<"struct(", Inner/binary, RestPart/binary, ")">>.

struct_rest_text(exact, _Inner) -> <<>>;
struct_rest_text(wildcard, <<>>) -> <<"**">>;
struct_rest_text(wildcard, _Inner) -> <<",**">>;
struct_rest_text(Var, <<>>) when is_binary(Var) -> <<"**", Var/binary>>;
struct_rest_text(Var, _Inner) when is_binary(Var) -> <<",**", Var/binary>>.

escape_field_name(Bin) ->
    << <<(case C of
            $\\ -> <<"\\\\">>;
            $" -> <<"\\\"">>;
            _ -> <<C>>
          end)/binary>> || <<C>> <= Bin >>.

%%====================================================================
%% Hash
%%====================================================================

-spec hash(gdbsp_column_type()) -> binary().
hash(Type) ->
    list_to_binary(gdbsp_hash:md5(canonical_text(Type))).

%%====================================================================
%% Parse canonical text back to gdbsp_column_type()
%%====================================================================

-spec parse_canonical_text(binary()) -> {ok, gdbsp_column_type()} | {error, term()}.
parse_canonical_text(Bin) when is_binary(Bin) ->
    try
        {Type, <<>>} = parse_ct(Bin),
        {ok, collapse(Type)}
    catch
        throw:{parse_error, _} = E -> {error, E};
        error:{badmatch, _} -> {error, {parse_error, unexpected_eos}};
        error:function_clause -> {error, {parse_error, unexpected_eos}};
        error:badarg -> {error, {parse_error, badarg}}
    end.

%% ── parse_ct ────────────────────────────────────────────────────────

parse_ct(Bin) ->
    {Name, Rest0} = parse_ct_ident(Bin),
    case Rest0 of
        <<"(", Rest1/binary>> ->
            case parse_ct_params_for(Name, Rest1) of
                {Params, <<")", Rest2/binary>>} ->
                    {build_ct_type(Name, Params), Rest2};
                {_Params, _Rest} ->
                    throw({parse_error, {unclosed_paren, Name}})
            end;
        _ ->
            {name_to_bare_type(Name), Rest0}
    end.

%% ── parse_ct_params_for — type-specific param parsing ───────────────

parse_ct_params_for(<<"numeric">>, Bin) ->
    {P, Rest0} = parse_ct_int(Bin),
    Rest1 = expect_ct(<<",">>, Rest0),
    {S, Rest2} = parse_ct_int(Rest1),
    {[P, S], Rest2};

parse_ct_params_for(<<"string">>, Bin) ->
    {E, Rest} = parse_ct_quoted_string(Bin),
    {[E], Rest};

parse_ct_params_for(<<"bytes">>, Bin) ->
    {N, Rest} = parse_ct_int(Bin),
    {[N], Rest};

parse_ct_params_for(<<"bits">>, Bin) ->
    {N, Rest} = parse_ct_int(Bin),
    {[N], Rest};

parse_ct_params_for(<<"optional">>, Bin) ->
    {T, Rest} = parse_ct(Bin),
    {[T], Rest};

parse_ct_params_for(<<"closure">>, Bin) ->
    {Params, Rest0} = parse_ct_closure_params(Bin, []),
    Rest1 = expect_ct(<<"->">>, Rest0),
    {RetType, Rest2} = parse_ct(Rest1),
    {[Params, RetType], Rest2};

parse_ct_params_for(<<"array">>, Bin) ->
    {ET, Rest0} = parse_ct(Bin),
    case Rest0 of
        <<")", _/binary>> ->
            {[ET, varsize], Rest0};
        <<",", Rest1/binary>> ->
            {Ints, Rest2} = parse_ct_int_list(Rest1),
            Dims = case Ints of
                [N] -> N;
                _ -> Ints
            end,
            {[ET, Dims], Rest2};
        _ ->
            throw({parse_error, {expected_comma_or_paren, Rest0}})
    end;

parse_ct_params_for(<<"map">>, Bin) ->
    {K, Rest0} = parse_ct(Bin),
    Rest1 = expect_ct(<<",">>, Rest0),
    {V, Rest2} = parse_ct(Rest1),
    {[K, V], Rest2};

parse_ct_params_for(<<"struct">>, Bin) ->
    {Fields, RestDesc, Rest} = parse_ct_struct_fields(Bin, []),
    {[maps:from_list(lists:reverse(Fields)), RestDesc], Rest};

parse_ct_params_for(<<"enum">>, Bin) ->
    {Names, Rest} = parse_ct_enum_names(Bin, []),
    {[Names], Rest};

parse_ct_params_for(<<"json">>, Bin) ->
    {T, Rest} = parse_ct(Bin),
    {[T], Rest};

parse_ct_params_for(<<"dynamic">>, Bin) ->
    {T, Rest} = parse_ct(Bin),
    {[T], Rest};

parse_ct_params_for(Name, _Bin) ->
    throw({parse_error, {unknown_type_name, Name}}).

parse_ct_enum_names(Bin, Acc) ->
    {Name, Rest0} = parse_ct_quoted_string(Bin),
    case Rest0 of
        <<")", _/binary>> ->
            {lists:reverse([Name | Acc]), Rest0};
        <<",", Rest1/binary>> ->
            parse_ct_enum_names(Rest1, [Name | Acc]);
        _ ->
            throw({parse_error, {expected_comma_or_close_paren, Rest0}})
    end.

%% ── parse_ct_struct_fields ──────────────────────────────────────────

parse_ct_struct_fields(Bin, Acc) ->
    case Bin of
        <<")", _/binary>> -> {Acc, exact, Bin};
        <<"**", Rest0/binary>> ->
            {RestDesc, Rest1} = parse_ct_struct_rest(Rest0),
            {Acc, RestDesc, Rest1};
        <<",", Rest/binary>> -> parse_ct_struct_fields(Rest, Acc);
        _ ->
            {Name, Rest0} = parse_ct_quoted_string(Bin),
            Rest1 = expect_ct(<<":">>, Rest0),
            {Type, Rest2} = parse_ct(Rest1),
            parse_ct_struct_fields(Rest2, [{Name, Type} | Acc])
    end.

%% After "**": a bare wildcard (next char ")") or a named row variable.
parse_ct_struct_rest(Bin) ->
    case take_ct_ident(Bin, <<>>) of
        {<<>>, Rest} -> {wildcard, Rest};
        {Name, Rest} -> {Name, Rest}
    end.

%% ── parse_ct_ident ──────────────────────────────────────────────────

parse_ct_ident(Bin) ->
    {Ident, Rest} = take_ct_ident(Bin, <<>>),
    case Ident of
        <<>> -> throw({parse_error, {expected_identifier, Bin}});
        _ -> {Ident, Rest}
    end.

take_ct_ident(<<C, Rest/binary>>, Acc)
  when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_ ->
    take_ct_ident(Rest, <<Acc/binary, C>>);
take_ct_ident(Rest, Acc) ->
    {Acc, Rest}.

%% ── parse_ct_int ────────────────────────────────────────────────────

parse_ct_int(Bin) ->
    {IntBin, Rest} = take_ct_digits(Bin, <<>>),
    case IntBin of
        <<>> -> throw({parse_error, {expected_integer, Bin}});
        _ -> {binary_to_integer(IntBin), Rest}
    end.

take_ct_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    take_ct_digits(Rest, <<Acc/binary, C>>);
take_ct_digits(Rest, Acc) ->
    {Acc, Rest}.

%% ── parse_ct_int_list (comma-separated) ─────────────────────────────

parse_ct_int_list(Bin) ->
    {N, Rest0} = parse_ct_int(Bin),
    case Rest0 of
        <<",", Rest1/binary>> ->
            {More, Rest2} = parse_ct_int_list(Rest1),
            {[N | More], Rest2};
        _ ->
            {[N], Rest0}
    end.

%% ── parse_ct_quoted_string ──────────────────────────────────────────

parse_ct_quoted_string(<<$", Rest/binary>>) ->
    parse_ct_qs_content(Rest, <<>>);
parse_ct_quoted_string(Bin) ->
    throw({parse_error, {expected_open_quote, Bin}}).

parse_ct_qs_content(<<$\\, $\\, Rest/binary>>, Acc) ->
    parse_ct_qs_content(Rest, <<Acc/binary, $\\>>);
parse_ct_qs_content(<<$\\, $", Rest/binary>>, Acc) ->
    parse_ct_qs_content(Rest, <<Acc/binary, $">>);
parse_ct_qs_content(<<$", Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_ct_qs_content(<<C, Rest/binary>>, Acc) ->
    parse_ct_qs_content(Rest, <<Acc/binary, C>>);
parse_ct_qs_content(<<>>, _Acc) ->
    throw({parse_error, unterminated_string}).

%% ── parse_ct_closure_params ─────────────────────────────────────────

parse_ct_closure_params(<<"->", _/binary>> = Rest, Acc) ->
    {lists:reverse(Acc), Rest};
parse_ct_closure_params(Bin, Acc) ->
    {Name, Rest0} = parse_ct_quoted_string(Bin),
    Rest1 = expect_ct(<<":">>, Rest0),
    {Type, Rest2} = parse_ct(Rest1),
    case Rest2 of
        <<",", Rest3/binary>> ->
            parse_ct_closure_params(Rest3, [{Name, Type} | Acc]);
        _ ->
            {lists:reverse([{Name, Type} | Acc]), Rest2}
    end.

%% ── expect_ct ───────────────────────────────────────────────────────

expect_ct(Expected, Bin) ->
    Size = byte_size(Expected),
    case Bin of
        <<Expected:Size/binary, Rest/binary>> -> Rest;
        _ -> throw({parse_error, {expected, Expected, Bin}})
    end.

%% ── build_ct_type ───────────────────────────────────────────────────

build_ct_type(<<"numeric">>, [P, S]) -> {numeric, P, S};
build_ct_type(<<"string">>, [E]) -> {string, E};
build_ct_type(<<"bytes">>, [N]) -> {bytes, N};
build_ct_type(<<"bits">>, [N]) -> {bits, N};
build_ct_type(<<"optional">>, [T]) -> {optional, T};
build_ct_type(<<"closure">>, [Params, RetType]) -> {closure, Params, RetType};
build_ct_type(<<"array">>, [T, varsize]) -> {array, T, varsize};
build_ct_type(<<"array">>, [T, N]) when is_integer(N) -> {array, T, N};
build_ct_type(<<"array">>, [T, Dims]) when is_list(Dims) -> {array, T, Dims};
build_ct_type(<<"map">>, [K, V]) -> {map, K, V};
build_ct_type(<<"struct">>, [Fields, Rest]) -> {struct, Fields, Rest};
build_ct_type(<<"enum">>, [Names]) -> {enum, Names};
build_ct_type(<<"json">>, [T]) -> {json, T};
build_ct_type(<<"dynamic">>, [T]) -> {dynamic, T}.

%% ── name_to_bare_type ───────────────────────────────────────────────

name_to_bare_type(<<"boolean">>) -> ?BOOL;
name_to_bare_type(<<"i8">>) -> i8;
name_to_bare_type(<<"i16">>) -> i16;
name_to_bare_type(<<"i32">>) -> i32;
name_to_bare_type(<<"i64">>) -> i64;
name_to_bare_type(<<"u8">>) -> u8;
name_to_bare_type(<<"u16">>) -> u16;
name_to_bare_type(<<"u32">>) -> u32;
name_to_bare_type(<<"u64">>) -> u64;
name_to_bare_type(<<"integer">>) -> integer;
name_to_bare_type(<<"f32">>) -> f32;
name_to_bare_type(<<"f64">>) -> f64;
name_to_bare_type(<<"numeric">>) -> numeric;
name_to_bare_type(<<"string">>) -> string;
name_to_bare_type(<<"string_with_encoding">>) -> string_with_encoding;
name_to_bare_type(<<"bytes">>) -> bytes;
name_to_bare_type(<<"bits">>) -> bits;
name_to_bare_type(<<"date">>) -> date;
name_to_bare_type(<<"time">>) -> time;
name_to_bare_type(<<"timestamp">>) -> timestamp;
name_to_bare_type(<<"timestamp_with_timezone">>) -> timestamp_with_timezone;
name_to_bare_type(<<"interval">>) -> interval;
name_to_bare_type(<<"json">>) -> json;
name_to_bare_type(<<"dynamic">>) -> dynamic;
name_to_bare_type(<<"null">>) -> absent;
name_to_bare_type(<<"absent">>) -> absent;
name_to_bare_type(<<"type">>) -> type;
name_to_bare_type(Name) -> throw({parse_error, {unknown_type_name, Name}}).

%%====================================================================
%% Collapse (normalize nested wrappers)
%%====================================================================

-spec collapse(gdbsp_column_type()) -> gdbsp_column_type().
collapse(absent) -> absent;
collapse({optional, {optional, T}}) -> collapse({optional, T});
collapse({optional, T}) -> {optional, collapse(T)};
collapse({closure, P1, {closure, P2, T}}) ->
    case merge_closure_params(P1 ++ P2, []) of
        {ok, Merged} -> collapse({closure, Merged, T});
        {error, Reason} -> erlang:error({closure_param_clash, Reason})
    end;
collapse({closure, Params, T}) ->
    {closure, Params, collapse(T)};
collapse({array, T, D}) -> {array, collapse(T), D};
collapse({map, K, V}) -> {map, collapse(K), collapse(V)};
collapse({struct, Fields, Rest}) ->
    {struct, maps:map(fun(_F, T) -> collapse(T) end, Fields), Rest};
collapse({numeric, P, S}) -> {numeric, P, S};
collapse({bytes, N}) -> {bytes, N};
collapse({bits, N}) -> {bits, N};
collapse({string, <<"UTF-8">>}) -> string;
collapse({string, E}) -> {string, E};
collapse({enum, _} = E) -> E;  %% no collapsing — optional(enum(...)) retains optional
collapse({dynamic, T}) -> {dynamic, collapse(T)};
collapse({json, T}) -> {json, collapse(T)};
collapse(T) when is_atom(T) -> T;
collapse({type_var, _} = TV) -> TV.

merge_closure_params([], Acc) ->
    {ok, lists:reverse(Acc)};
merge_closure_params([{Name, Type} | Rest], Acc) ->
    case lists:keyfind(Name, 1, Acc) of
        {Name, Type} -> merge_closure_params(Rest, Acc);
        {Name, OtherType} -> {error, {param_type_clash, Name, Type, OtherType}};
        false -> merge_closure_params(Rest, [{Name, Type} | Acc])
    end.

%%====================================================================
%% Assignability
%%====================================================================

-spec is_assignable(gdbsp_column_type(), gdbsp_column_type()) -> boolean().
is_assignable(Src, Tgt) ->
    is_assignable_inner(collapse(Src), collapse(Tgt)).

is_assignable_inner(Src, Src) -> true;
is_assignable_inner(absent, {optional, _}) -> true;
is_assignable_inner(absent, _) -> false;
is_assignable_inner(Src, dynamic) -> true;
is_assignable_inner({dynamic, _}, dynamic) -> true;
is_assignable_inner({dynamic, T}, Tgt) -> is_assignable_inner(T, Tgt);
is_assignable_inner(Src, {dynamic, T}) -> is_assignable_inner(Src, T);
is_assignable_inner({json, _}, json) -> true;
is_assignable_inner({json, T}, Tgt) -> is_assignable_inner(T, Tgt);
is_assignable_inner(Src, {json, T}) -> is_assignable_to_json(Src) andalso is_assignable_inner(Src, T);
is_assignable_inner(Src, Tgt) ->
    case Tgt of
        {enum, Names}       -> is_assignable_to_enum(Src, Names);
        {optional, Inner} -> is_assignable_to_optional(Src, Inner);
        {closure, _, _} -> is_assignable_to_closure(Src, Tgt);
        numeric            -> is_assignable_to_numeric(Src);
        bytes              -> is_assignable_to_bytes(Src);
        bits               -> is_assignable_to_bits(Src);
        json               -> is_assignable_to_json(Src);
        {array, Elem, Shape} -> is_assignable_to_array(Src, Elem, Shape);
        {map, K, V}        -> is_assignable_to_map(Src, K, V);
        {struct, _, _}     -> is_assignable_to_struct(Src, Tgt);
        {bytes, _N}        -> false;
        {numeric, _P, _S}  -> false;
        {string, _E}       -> false;
        {bits, _N}         -> false;
        _ when is_atom(Tgt) ->
            is_int_widening(Src, Tgt)
    end.

is_assignable_to_optional(absent, _Inner) -> true;
is_assignable_to_optional(Src, Inner) ->
    is_assignable_inner(Src, Inner).

is_assignable_to_enum({enum, SrcNames}, TgtNames) ->
    sets:is_subset(sets:from_list(SrcNames), sets:from_list(TgtNames));
is_assignable_to_enum(absent, _TgtNames) -> false;
is_assignable_to_enum(_, _TgtNames) -> false.

is_assignable_to_closure({closure, [], SrcInner}, {closure, [], TgtInner}) ->
    is_assignable_inner(SrcInner, TgtInner);
is_assignable_to_closure(Src, {closure, [], TgtInner}) ->
    is_assignable_inner(Src, TgtInner);
is_assignable_to_closure({closure, SrcParams, SrcInner}, {closure, TgtParams, TgtInner}) ->
    lists:sort(SrcParams) =:= lists:sort(TgtParams) andalso
    is_assignable_inner(SrcInner, TgtInner);
is_assignable_to_closure(_, _) -> false.

is_assignable_to_numeric({numeric, _, _}) -> true;
is_assignable_to_numeric(integer) -> true;
is_assignable_to_numeric(i8)  -> true;
is_assignable_to_numeric(i16) -> true;
is_assignable_to_numeric(i32) -> true;
is_assignable_to_numeric(i64) -> true;
is_assignable_to_numeric(u8)  -> true;
is_assignable_to_numeric(u16) -> true;
is_assignable_to_numeric(u32) -> true;
is_assignable_to_numeric(u64) -> true;
is_assignable_to_numeric(_) -> false.

is_assignable_to_bytes({bytes, _}) -> true;
is_assignable_to_bytes(_) -> false.

is_assignable_to_bits({bits, _}) -> true;
is_assignable_to_bits(_) -> false.

is_assignable_to_json(string) -> true;
is_assignable_to_json(f64) -> true;
is_assignable_to_json({array, Elem, _}) -> is_assignable_inner(Elem, json);
is_assignable_to_json({map, K, V}) -> is_assignable_inner(K, string) andalso is_assignable_inner(V, json);
is_assignable_to_json({enum, Names}) ->
    is_assignable_to_enum({enum, Names}, [<<"true">>, <<"false">>, <<"null">>]);
is_assignable_to_json(_) -> false.

is_assignable_to_array({array, SrcElem, SrcShape}, TgtElem, TgtShape) ->
    ShapeOk = case {SrcShape, TgtShape} of
        {Same, Same} -> true;
        {SrcShape2, varsize} when is_integer(SrcShape2) -> true;
        {SrcShape2, varsize} when is_list(SrcShape2) -> true;
        _ -> false
    end,
    ShapeOk andalso is_assignable_inner(SrcElem, TgtElem);
is_assignable_to_array(_, _, _) -> false.

is_assignable_to_map({map, SrcK, SrcV}, TgtK, TgtV) ->
    is_assignable_inner(SrcK, TgtK) andalso is_assignable_inner(SrcV, TgtV);
is_assignable_to_map(_, _, _) -> false.

%% struct(**) target — any concrete struct is assignable to it.
is_assignable_to_struct({struct, SrcFields, _SrcRest}, {struct, TgtFields, wildcard})
        when is_map(SrcFields), map_size(TgtFields) =:= 0 ->
    true;
is_assignable_to_struct({struct, SrcFields, _SrcRest}, {struct, TgtFields, exact})
        when is_map(SrcFields), is_map(TgtFields) ->
    maps:keys(SrcFields) =:= maps:keys(TgtFields) andalso
    maps:fold(fun(Field, TgtT, true) ->
        case maps:find(Field, SrcFields) of
            {ok, SrcT} -> is_assignable_inner(SrcT, TgtT);
            error -> false
        end
    end, true, TgtFields);
is_assignable_to_struct(_, _) -> false.

%%--------------------------------------------------------------------
%% Integer widening
%%--------------------------------------------------------------------

is_int_widening(Src, Tgt) ->
    case {Src, Tgt} of
        {i8, i16} -> true;
        {i8, i32} -> true;
        {i8, i64} -> true;
        {i8, integer} -> true;
        {i16, i32} -> true;
        {i16, i64} -> true;
        {i16, integer} -> true;
        {i32, i64} -> true;
        {i32, integer} -> true;
        {i64, integer} -> true;
        {u8, u16} -> true;
        {u8, u32} -> true;
        {u8, u64} -> true;
        {u8, integer} -> true;
        {u16, u32} -> true;
        {u16, u64} -> true;
        {u16, integer} -> true;
        {u32, u64} -> true;
        {u32, integer} -> true;
        {u64, integer} -> true;
        {u8, i16} -> true;
        {u8, i32} -> true;
        {u8, i64} -> true;
        {u16, i32} -> true;
        {u16, i64} -> true;
        {u32, i64} -> true;
        _ -> false
    end.

%%====================================================================
%% Runtime filter
%%====================================================================

-spec requires_runtime_filter(gdbsp_column_type(), gdbsp_column_type()) -> boolean().
requires_runtime_filter(Src, Tgt) ->
    Src1 = collapse(Src),
    Tgt1 = collapse(Tgt),
    (not is_assignable_inner(Src1, Tgt1)) andalso has_runtime_filter(Src1, Tgt1).

has_runtime_filter({optional, Inner}, Tgt) when Tgt =/= dynamic, Tgt =/= absent ->
    is_assignable_inner(Inner, Tgt) orelse has_runtime_filter(Inner, Tgt);
has_runtime_filter({optional, _}, {optional, _}) -> true;
has_runtime_filter(dynamic, Tgt) when Tgt =/= dynamic -> true;
has_runtime_filter({dynamic, T}, Tgt) -> not is_assignable_inner(T, Tgt);
has_runtime_filter(json, string) -> true;
has_runtime_filter(json, f64) -> true;
has_runtime_filter(json, {array, json, _}) -> true;
has_runtime_filter(json, {map, string, json}) -> true;
has_runtime_filter(json, {enum, Names}) ->
    sets:is_subset(sets:from_list(Names),
                   sets:from_list([<<"true">>, <<"false">>, <<"null">>]));
has_runtime_filter({enum, SrcNames}, {enum, TgtNames}) ->
    sets:is_subset(sets:from_list(TgtNames), sets:from_list(SrcNames));
has_runtime_filter(bytes, {bytes, _}) -> true;
has_runtime_filter({array, _, varsize}, {array, _, N}) when is_integer(N) -> true;
has_runtime_filter(_, _) -> false.

%%====================================================================
%% Widen / join two types
%%====================================================================

-spec widen(gdbsp_column_type(), gdbsp_column_type()) -> {ok, gdbsp_column_type()} | {error, term()}.
widen(A, B) ->
    widen_impl(collapse(A), collapse(B)).

widen_impl(Same, Same) -> {ok, Same};
widen_impl(absent, dynamic) -> {error, incompatible};
widen_impl(dynamic, absent) -> {error, incompatible};
widen_impl({optional, dynamic}, dynamic) -> {error, incompatible};
widen_impl(dynamic, {optional, dynamic}) -> {error, incompatible};
widen_impl({dynamic, _}, dynamic) -> {ok, dynamic};
widen_impl(dynamic, {dynamic, _}) -> {ok, dynamic};
widen_impl({dynamic, A}, {dynamic, B}) ->
    case widen_impl(A, B) of
        {ok, W} -> {ok, {dynamic, W}};
        Error -> Error
    end;
widen_impl({json, _}, json) -> {ok, json};
widen_impl(json, {json, _}) -> {ok, json};
widen_impl({json, A}, {json, B}) ->
    case widen_impl(A, B) of
        {ok, W} -> {ok, {json, W}};
        Error -> Error
    end;
widen_impl(_, dynamic) -> {ok, dynamic};
widen_impl(dynamic, _) -> {ok, dynamic};
widen_impl(absent, {optional, T}) -> {ok, {optional, T}};
widen_impl({optional, T}, absent) -> {ok, {optional, T}};
widen_impl(absent, T) when T =/= absent -> {ok, {optional, T}};
widen_impl(T, absent) when T =/= absent -> {ok, {optional, T}};
widen_impl({optional, S}, {optional, T}) ->
    case widen_impl(S, T) of
        {ok, W} -> {ok, {optional, W}};
        Error -> Error
    end;
widen_impl({optional, S}, T) ->
    case widen_impl(S, T) of
        {ok, W} -> {ok, {optional, W}};
        Error -> Error
    end;
widen_impl(T, {optional, S}) ->
    case widen_impl(T, S) of
        {ok, W} -> {ok, {optional, W}};
        Error -> Error
    end;
widen_impl({closure, P, S}, {closure, P, T}) ->
    case widen_impl(S, T) of
        {ok, W} -> {ok, {closure, P, W}};
        Error -> Error
    end;
widen_impl(S, {closure, [], T}) ->
    case widen_impl(S, T) of
        {ok, W} -> {ok, {closure, [], W}};
        Error -> Error
    end;
widen_impl({closure, [], S}, T) ->
    case widen_impl(S, T) of
        {ok, W} -> {ok, {closure, [], W}};
        Error -> Error
    end;
widen_impl({closure, _, _}, _) -> {error, incompatible};
widen_impl(_, {closure, _, _}) -> {error, incompatible};
widen_impl({enum, S}, {enum, T}) ->
    {ok, {enum, lists:usort(S ++ T)}};
widen_impl(Src, Tgt) when is_atom(Src), is_atom(Tgt) ->
    widen_scalar(Src, Tgt);
widen_impl({bytes, N}, {bytes, M}) when N =:= M -> {ok, {bytes, N}};
widen_impl({bytes, _}, {bytes, _}) -> {ok, bytes};
widen_impl(bytes, {bytes, _}) -> {ok, bytes};
widen_impl({bytes, _}, bytes) -> {ok, bytes};
widen_impl({numeric, P, S}, {numeric, P, S}) -> {ok, {numeric, P, S}};
widen_impl({numeric, _, _}, {numeric, _, _}) -> {ok, numeric};
widen_impl(numeric, {numeric, _, _}) -> {ok, numeric};
widen_impl({numeric, _, _}, numeric) -> {ok, numeric};
widen_impl(integer, numeric) -> {ok, numeric};
widen_impl(numeric, integer) -> {ok, numeric};
widen_impl({array, SrcE, SrcS}, {array, TgtE, TgtS}) ->
    case widen_impl(SrcE, TgtE) of
        {ok, Elem} ->
            Shape = case {SrcS, TgtS} of
                {Same, Same} -> Same;
                {varsize, _} -> varsize;
                {_, varsize} -> varsize;
                {N, N} when is_integer(N) -> N;
                {Dims, Dims} when is_list(Dims) -> Dims;
                _ -> error
            end,
            case Shape of
                error -> {error, incompatible};
                _ -> {ok, {array, Elem, Shape}}
            end;
        Error -> Error
    end;
widen_impl({map, SrcK, SrcV}, {map, TgtK, TgtV}) ->
    case {widen_impl(SrcK, TgtK), widen_impl(SrcV, TgtV)} of
        {{ok, K}, {ok, V}} -> {ok, {map, K, V}};
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E
    end;
widen_impl({struct, SrcFields, Rest}, {struct, TgtFields, Rest}) ->
    case maps:keys(SrcFields) =:= maps:keys(TgtFields) of
        false -> {error, incompatible};
        true ->
            Widened = maps:fold(fun(Field, TgtT, {ok, Acc}) ->
                SrcT = maps:get(Field, SrcFields),
                case widen_impl(SrcT, TgtT) of
                    {ok, WT} -> {ok, Acc#{Field => WT}};
                    Error -> Error
                end
            end, {ok, #{}}, TgtFields),
            case Widened of
                {ok, Fields} -> {ok, {struct, Fields, Rest}};
                Error -> Error
            end
    end;
widen_impl(_, _) -> {error, incompatible}.

%%--------------------------------------------------------------------
%% Scalar and integer widening for the widen function
%%--------------------------------------------------------------------

widen_scalar(Src, numeric) when Src =/= numeric ->
    case is_atom_integer_type(Src) of
        true -> {ok, numeric};
        false -> {error, incompatible}
    end;
widen_scalar(numeric, Tgt) when Tgt =/= numeric ->
    widen_scalar(Tgt, numeric);
widen_scalar(Src, Tgt) ->
    case is_int_widening(Src, Tgt) of
        true -> {ok, Tgt};
        false ->
            case is_int_widening(Tgt, Src) of
                true -> {ok, Src};
                false -> {error, incompatible}
            end
    end.

is_atom_integer_type(i8)  -> true;
is_atom_integer_type(i16) -> true;
is_atom_integer_type(i32) -> true;
is_atom_integer_type(i64) -> true;
is_atom_integer_type(u8)  -> true;
is_atom_integer_type(u16) -> true;
is_atom_integer_type(u32) -> true;
is_atom_integer_type(u64) -> true;
is_atom_integer_type(integer) -> true;
is_atom_integer_type(_) -> false.

%%====================================================================
%% Join restriction helper
%%====================================================================

-spec contains_closure_or_any(gdbsp_column_type()) -> boolean().
contains_closure_or_any(dynamic) -> true;
contains_closure_or_any({dynamic, _}) -> true;
contains_closure_or_any({json, _}) -> false;
contains_closure_or_any(absent) -> false;
contains_closure_or_any({closure, _, _}) -> true;
contains_closure_or_any({optional, T}) -> contains_closure_or_any(T);
contains_closure_or_any({array, T, _}) -> contains_closure_or_any(T);
contains_closure_or_any({map, K, V}) ->
    contains_closure_or_any(K) orelse contains_closure_or_any(V);
contains_closure_or_any({struct, Fields, exact}) ->
    maps:fold(fun(_F, T, false) -> contains_closure_or_any(T);
                 (_F, _T, true) -> true end, false, Fields);
contains_closure_or_any({struct, _Fields, _Rest}) -> true;
contains_closure_or_any(_) -> false.
