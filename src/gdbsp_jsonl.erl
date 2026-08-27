%%%-------------------------------------------------------------------
%%% @doc JSONL line encoding/decoding shared by the offline CLI and the
%%% HTTP front-end.
%%%
%%% One line per delta: a two-element array `[Weight, Row]`. `Row` is a
%%% JSON object decoded against the source/output type. This module owns
%%% the line format; callers own files, sockets, and error surfaces.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_jsonl).

-export([decode_line/2, decode_body/2, encode_line/1]).
-export([format_reason/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Decode a single JSONL line into a {Weight, Struct} delta.
-spec decode_line(term(), binary()) ->
    {ok, {integer(), term()}} | {error, term()}.
decode_line(Type, Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        [W, RowJson] when is_integer(W) ->
            case gdbsp_value_json:decode_row(Type, RowJson) of
                {ok, Decoded} ->
                    {ok, {W, gdbsp_struct:map_to_struct(Decoded, Type)}};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            {error, {bad_line, <<"expected [weight, row]">>}}
    catch
        _:_ -> {error, {bad_json, Bin}}
    end.

%% @doc Decode a whole JSONL body (one delta per line). Blank lines are
%% skipped. On failure the 1-indexed line number is reported.
-spec decode_body(term(), binary()) ->
    {ok, [{integer(), term()}]} | {error, {pos_integer(), term()}}.
decode_body(Type, Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    decode_lines(Lines, Type, 1, []).

%% @doc Encode a JSONL line (or header object) to its wire form.
-spec encode_line(term()) -> binary().
encode_line(Line) ->
    jsx:encode(Line).

%% @doc Render a decode reason as a readable message.
-spec format_reason(term()) -> iolist().
format_reason({missing_column, Col}) ->
    ["missing column: ", Col];
format_reason({missing_field, F}) ->
    ["missing field: ", F];
format_reason({type_mismatch, _T, _V}) ->
    "type mismatch";
format_reason({bad_line, Msg}) ->
    Msg;
format_reason({bad_json, _Bin}) ->
    "invalid JSON";
format_reason(Reason) ->
    io_lib:format("~p", [Reason]).

%%====================================================================
%% Internal
%%====================================================================

decode_lines([], _Type, _N, Acc) ->
    {ok, lists:reverse(Acc)};
decode_lines([Line | Rest], Type, N, Acc) ->
    case strip_cr(Line) of
        <<>> ->
            decode_lines(Rest, Type, N, Acc);
        Trimmed ->
            case decode_line(Type, Trimmed) of
                {ok, Row} -> decode_lines(Rest, Type, N + 1, [Row | Acc]);
                {error, Reason} -> {error, {N, Reason}}
            end
    end.

strip_cr(Line) ->
    Size = byte_size(Line),
    case Size > 0 andalso binary:last(Line) =:= $\r of
        true -> binary:part(Line, 0, Size - 1);
        false -> Line
    end.
