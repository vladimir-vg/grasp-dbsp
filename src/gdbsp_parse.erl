-module(gdbsp_parse).

-export([parse/2, parse_string/2]).

-include("gdbsp_parse.hrl").

-record(st, {
    line       = 0 :: pos_integer(),
    nodes      = [] :: [#gdbsp_node_def{}],
    typespecs  = [] :: [#gdbsp_typespec{}],
    circuits   = [] :: [#gdbsp_circuit_def{}]
}).

%%====================================================================
%% Public API
%%====================================================================

-spec parse(file:filename(), map()) ->
    {ok, #gdbsp_program{}} | {error, term()}.
parse(File, _Opts) ->
    case file:read_file(File) of
        {ok, Bin} -> parse_string(Bin, #{});
        {error, _} = Err -> Err
    end.

-spec parse_string(binary(), map()) ->
    {ok, #gdbsp_program{}} | {error, term()}.
parse_string(Bin, _Opts) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    try parse_lines(Lines, #st{}) of
        St ->
            Prog = #gdbsp_program{
                nodes     = lists:reverse(St#st.nodes),
                typespecs = lists:reverse(St#st.typespecs),
                circuits  = lists:reverse(St#st.circuits)
            },
            {ok, Prog}
    catch
        throw:{parse_error, Line, Msg} ->
            {error, {Line, Msg}};
        throw:{parse_error, Msg} ->
            {error, {1, Msg}}
    end.

%%====================================================================
%% Line processing
%%====================================================================

parse_lines([], St) -> St;
parse_lines([<<>> | Rest], St) ->
    parse_lines(Rest, St#st{line = St#st.line + 1});
parse_lines([Line0 | Rest], St0) ->
    Line = trim_right(Line0),
    St = St0#st{line = St0#st.line + 1},
    case Line of
        <<"#", _/binary>> -> parse_lines(Rest, St);
        <<>> -> parse_lines(Rest, St);
        <<"circuit ", _/binary>> ->
            parse_circuit_def(Line, St, Rest);
        _ ->
            case try_node_def(Line, St, Rest) of
                {done, St2} ->
                    St2;
                false ->
                    parse_decl(Line, St, Rest)
            end
    end.

parse_circuit_def(Line, St, Rest) ->
    case parse_circuit_header(Line, St#st.line) of
        {ok, {Name, Params}} ->
            {BodyLines, Remaining} = collect_circuit_body(Rest, []),
            BodyNodes = lists:map(
                fun(BodyLine) ->
                    case try_node_def_no_multi(BodyLine, St) of
                        {ok, Node} -> Node;
                        {error, ErrLine, ErrMsg} ->
                            parse_error(ErrLine, "~s", [ErrMsg])
                    end
                end,
                BodyLines),
            BodySt = St#st{line = St#st.line + length(BodyLines)},
            Def = #gdbsp_circuit_def{name = Name, params = Params, body = BodyNodes},
            parse_lines(Remaining,
                        BodySt#st{circuits = [Def | BodySt#st.circuits]});
        {error, Reason} ->
            parse_error(St#st.line, "~s", [Reason])
    end.

try_node_def_no_multi(Line0, St) ->
    Line = trim_left(trim_right(Line0)),
    case try_node_def_single(Line, St) of
        {done, Node} -> {ok, Node};
        false -> {error, St#st.line, iolist_to_binary(
                     io_lib:format("invalid body node: ~s", [Line]))}
    end.

try_node_def_single(Line, St) ->
    case binary:split(Line, <<" := ">>) of
        [Name, OpCall] ->
            case binary:split(trim(OpCall), <<"(">>) of
                [Op, <<")">>] ->
                    {done, mk_node(Name, Op, [], St)};
                [Op, ArgsBin] ->
                    {_, Inner} = take_single_line_args(ArgsBin),
                    Args = parse_args(Inner),
                    {done, mk_node(Name, Op, Args, St)};
                _ -> false
            end;
        _ -> false
    end.

take_single_line_args(Bin) ->
    case binary:match(Bin, <<")">>) of
        {Pos, 1} ->
            <<Inner:Pos/binary, ")", _/binary>> = Bin,
            {closed, Inner};
        nomatch ->
            {open, Bin}
    end.

parse_circuit_header(Line, LineNum) ->
    %% Line looks like: "circuit name(key1: internal1, key2: internal2):"
    <<"circuit ", Rest0/binary>> = Line,
    case binary:split(trim_right(Rest0), <<"(">>) of
        [Name0, ParamsAndColon] ->
            Name = trim(Name0),
            %% ParamsAndColon looks like: "key1: internal1, key2: internal2):"
            case binary:match(ParamsAndColon, <<"):">>) of
                {Pos2, _} ->
                    <<ParamsBin:Pos2/binary, _:2/binary>> = ParamsAndColon,
                    Params = parse_circuit_params(ParamsBin, LineNum),
                    {ok, {Name, Params}};
                nomatch ->
                    {error, <<"expected '):' after circuit parameters">>}
            end;
        _ ->
            {error, <<"expected '(' after circuit name">>}
    end.

parse_circuit_params(Bin, _LineNum) ->
    Pairs = split_top(trim_trailing_comma(Bin), <<",">>),
    lists:foldl(
        fun(Pair, Acc) ->
            TrimPair = trim(Pair),
            case binary:split(TrimPair, <<":">>) of
                [Key, Val] ->
                    KeyAtom = binary_to_atom(trim(Key), utf8),
                    Acc#{KeyAtom => trim(Val)};
                _ ->
                    Acc
            end
        end,
        #{},
        Pairs
    ).

collect_circuit_body([], Acc) ->
    {lists:reverse(Acc), []};
collect_circuit_body([Line0 | Rest], Acc) ->
    Line = trim_right(Line0),
    case Line of
        <<>> -> {lists:reverse(Acc), Rest};
        <<"#", _/binary>> -> collect_circuit_body(Rest, Acc);
        _ ->
            case is_body_node_line(Line0) of
                true -> collect_circuit_body(Rest, [Line0 | Acc]);
                false -> {lists:reverse(Acc), [Line0 | Rest]}
            end
    end.

is_body_node_line(Line0) ->
    Line = trim_right(Line0),
    case binary:match(Line, <<" := ">>) of
        nomatch -> false;
        _ -> true
    end.

parse_decl(Line, St, Rest) ->
    %% Use binary:split instead of pattern matching with variable-size prefixes
    case binary:split(Line, <<" :: ">>) of
        [Name, <<"function(", Rest0/binary>>] ->
            parse_fn_decl(Name, function, Rest0, St, Rest);
        [Name, <<"aggregate_function(", Rest0/binary>>] ->
            parse_fn_decl(Name, aggregate_function, Rest0, St, Rest);
        [Name, TypeBin] ->
            parse_type_ann(Name, trim(TypeBin), St, Rest);
        _ ->
            parse_error(St#st.line, "unrecognized declaration: ~s", [Line])
    end.

%%====================================================================
%% Node definitions
%%====================================================================

try_node_def(Line, St, Rest) ->
    case binary:split(Line, <<" := ">>) of
        [Name, OpCall] ->
            TrimmedCall = trim(OpCall),
            case binary:match(TrimmedCall, <<"(">>) of
                nomatch ->
                    case binary:match(TrimmedCall, <<".">>) of
                        nomatch -> false;
                        _ ->
                            Node = mk_circuit_access_node(Name, TrimmedCall, St),
                            {done, parse_lines(Rest, St#st{nodes = [Node | St#st.nodes]})}
                    end;
                _ ->
                    case split_op_inner(TrimmedCall) of
                        {Op, <<")">>} ->
                            Node = mk_node(Name, Op, [], St),
                            {done, parse_lines(Rest, St#st{nodes = [Node | St#st.nodes]})};
                        {Op, Inner} ->
                            {Args, Remaining, St2} = collect_node_args_inner(OpCall, Op, Inner, St, Rest),
                            Node = mk_node(Name, Op, Args, St),
                            {done, parse_lines(Remaining, St2#st{nodes = [Node | St2#st.nodes]})}
                    end
            end;
        _ ->
            false
    end.

mk_circuit_access_node(Name, VarField, St) ->
    case binary:split(VarField, <<".">>) of
        [VarBin, FieldBin] ->
            #gdbsp_node_def{
                name = Name,
                op   = circuit_access,
                args = [{var, trim(VarBin)}, {var, trim(FieldBin)}],
                line = St#st.line
            };
        _ ->
            parse_error(St#st.line, "invalid circuit access: ~s", [VarField])
    end.

split_op_inner(OpCall) ->
    case binary:split(OpCall, <<"(">>) of
        [Op, Inner] ->
            case Op of
                <<"fixpoint ", CName/binary>> ->
                    {<<"fixpoint">>, <<CName/binary, "(", Inner/binary>>};
                _ ->
                    {Op, Inner}
            end;
        _ ->
            false
    end.

collect_node_args_inner(_OpCall, Op, Inner, St, Rest) ->
    case Op of
        <<"fixpoint">> ->
            case binary:match(Inner, <<"(">>) of
                nomatch ->
                    {[trim(Inner)], Rest, St};
                {ParenPos, 1} ->
                    CName = trim(binary:part(Inner, 0, ParenPos)),
                    <<_:ParenPos/binary, "(", More/binary>> = Inner,
                    case content_between_parens(More, 1, 0, <<>>, false) of
                        {closed, KwArgsStr} ->
                            KwTokens = parse_args_raw(KwArgsStr),
                            {[CName | KwTokens], Rest, St};
                        {open, _} ->
                            {[CName], Rest, St}
                    end
            end;
        _ ->
            case extract_parens_content(Inner) of
                {closed, InnerClean} ->
                    case is_multiline(InnerClean, Rest) of
                        {true, Inner2, Remaining} ->
                            Args = parse_args(Inner2),
                            Remaining2 = skip_trailing_paren(Remaining),
                            Consumed = length(Rest) - length(Remaining2),
                            {Args, Remaining2, St#st{line = St#st.line + Consumed}};
                        false ->
                            Args = parse_args(InnerClean),
                            {Args, Rest, St}
                    end;
                {open, _} ->
                    {[], Rest, St}
            end
    end.

extract_parens_content(Inner) ->
    case binary:match(Inner, <<"(">>) of
        nomatch ->
            Stripped = strip_trailing_paren(Inner),
            {closed, Stripped};
        {Pos, 1} ->
            <<_:Pos/binary, "(", More/binary>> = Inner,
            content_between_parens(More, 1, 0, <<>>, false)
    end.

collect_node_args(OpCall, Op, St, Rest) ->
    %% OpCall looks like "map(src, fn)"
    %% We need to extract everything between the first "(" and the matching ")"
    OpLen = byte_size(Op),
    <<_:OpLen/binary, Rest0/binary>> = OpCall,
    case Rest0 of
        <<"(", _/binary>> ->
            %% Extract inner content, handling nested parens/brackets
            {_, Inner} = extract_parens(Rest0),
            case is_multiline(Inner, Rest) of
                {true, Inner2, Remaining} ->
                    Args = parse_args(Inner2),
                    Remaining2 = skip_trailing_paren(Remaining),
                    Consumed = length(Rest) - length(Remaining2),
                    {Args, Remaining2, St#st{line = St#st.line + Consumed}};
                false ->
                    Args = parse_args(Inner),
                    {Args, Rest, St}
            end;
        _ ->
            {[], Rest, St}
    end.

is_multiline(Inner, [NextLine0 | Rest]) ->
    NextLine = trim_right(NextLine0),
    case is_continuation(NextLine) of
        true ->
            {Lines, Remaining} = collect_continuation_lines([NextLine], Rest),
            Continued = <<Inner/binary, ",", (iolist_to_binary(Lines))/binary>>,
            {true, trim_trailing_comma(Continued), Remaining};
        false ->
            false
    end;
is_multiline(_, []) -> false.

collect_continuation_lines(Acc, [Line0 | Rest]) ->
    Line = trim_right(Line0),
    case is_continuation(Line) of
        true -> collect_continuation_lines([Line | Acc], Rest);
        false -> {lists:reverse(Acc), [Line0 | Rest]}
    end;
collect_continuation_lines(Acc, []) ->
    {lists:reverse(Acc), []}.

skip_trailing_paren([]) -> [];
skip_trailing_paren([Line0 | Rest]) ->
    case trim(trim_right(Line0)) of
        <<")">> -> Rest;
        <<")", _/binary>> = T ->
            case binary:last(T) =:= $, of
                true -> Rest;
                false -> [Line0 | Rest]
            end;
        _ -> [Line0 | Rest]
    end.

is_continuation(<<>>) -> false;
is_continuation(<<"#", _/binary>>) -> false;
is_continuation(Line) ->
    Trimmed0 = trim(trim_right(Line)),
    Trimmed = case binary:last(Trimmed0) of
        $, -> binary:part(Trimmed0, 0, byte_size(Trimmed0) - 1);
        _ -> Trimmed0
    end,
    case binary:match(Trimmed, <<" ::">>) of
        nomatch ->
            case binary:match(Trimmed, <<" := ">>) of
                nomatch ->
                    Trimmed =/= <<")">> andalso Trimmed =/= <<>>;
                _ -> false
            end;
        _ -> false
    end.

content_between_parens(<<>>, _Depth, _Quote, Acc, _Esc) ->
    {open, trim_right(Acc)};
content_between_parens(<<$\\, C, Rest/binary>>, D, Q, Acc, _Esc) ->
    content_between_parens(Rest, D, Q, <<Acc/binary, $\\, C>>, true);
content_between_parens(<<$", Rest/binary>>, D, Q, Acc, _Esc) ->
    content_between_parens(Rest, D, 1 - Q, <<Acc/binary, $">>, false);
content_between_parens(<<$(, Rest/binary>>, D, 0, Acc, _Esc) ->
    content_between_parens(Rest, D + 1, 0, <<Acc/binary, $(>>, false);
content_between_parens(<<$), Rest/binary>>, 1, 0, Acc, _Esc) ->
    {closed, trim_right(Acc)};
content_between_parens(<<$), Rest/binary>>, D, 0, Acc, _Esc) when D > 1 ->
    content_between_parens(Rest, D - 1, 0, <<Acc/binary, $)>>, false);
content_between_parens(<<$[, Rest/binary>>, D, 0, Acc, _Esc) ->
    content_between_parens(Rest, D + 1000, 0, <<Acc/binary, $[>>, false);
content_between_parens(<<$], Rest/binary>>, D, 0, Acc, _Esc) when D >= 1000 ->
    content_between_parens(Rest, D - 1000, 0, <<Acc/binary, $]>>, false);
content_between_parens(<<C, Rest/binary>>, D, Q, Acc, _Esc) ->
    content_between_parens(Rest, D, Q, <<Acc/binary, C>>, false).

extract_parens(Bin) ->
    case binary:match(Bin, <<"(">>) of
        {Pos, 1} ->
            PrefixSize = Pos + 1,
            <<_:PrefixSize/binary, Rest/binary>> = Bin,
            content_between_parens(Rest, 1, 0, <<>>, false);
        nomatch ->
            {open, Bin}
    end.

extract_brackets(Bin) ->
    case binary:match(Bin, <<"[">>) of
        {Pos, 1} ->
            PrefixSize = Pos + 1,
            <<_:PrefixSize/binary, Rest/binary>> = Bin,
            bracket_content(Rest, <<>>);
        nomatch ->
            Bin
    end.

bracket_content(<<>>, Acc) -> Acc;
bracket_content(<<$\\, C, Rest/binary>>, Acc) ->
    bracket_content(Rest, <<Acc/binary, $\\, C>>);
bracket_content(<<$", Rest/binary>>, Acc) ->
    bracket_content_quote(Rest, <<Acc/binary, $">>);
bracket_content(<<$], Rest/binary>>, Acc) ->
    trim_right(Acc);
bracket_content(<<C, Rest/binary>>, Acc) ->
    bracket_content(Rest, <<Acc/binary, C>>).

bracket_content_quote(<<>>, Acc) -> Acc;
bracket_content_quote(<<$", Rest/binary>>, Acc) ->
    bracket_content(Rest, <<Acc/binary, $">>);
bracket_content_quote(<<$\\, C, Rest/binary>>, Acc) ->
    bracket_content_quote(Rest, <<Acc/binary, $\\, C>>);
bracket_content_quote(<<C, Rest/binary>>, Acc) ->
    bracket_content_quote(Rest, <<Acc/binary, C>>).

trim_trailing_comma(Bin) ->
    case byte_size(Bin) > 0 andalso binary:last(Bin) =:= $, of
        true -> binary:part(Bin, 0, byte_size(Bin) - 1);
        false -> Bin
    end.

mk_node(Name, OpBin, Args, St) ->
    known_op(OpBin) orelse parse_error(St#st.line, "unknown operator: ~s", [OpBin]),
    OpAtom = binary_to_atom(OpBin, utf8),
    ParArgs = lists:map(fun parse_node_arg/1, Args),
    #gdbsp_node_def{
        name = Name,
        op   = OpAtom,
        args = ParArgs,
        line = St#st.line
    }.

%% Minimal set (12) + extended (4)
known_op(<<"source">>)             -> true;
known_op(<<"delay">>)              -> true;
known_op(<<"integrate">>)          -> true;
known_op(<<"differentiate">>)      -> true;
known_op(<<"distinct">>)           -> true;
known_op(<<"plus">>)               -> true;
known_op(<<"neg">>)                -> true;
known_op(<<"map">>)                -> true;
known_op(<<"flat_map">>)           -> true;
known_op(<<"join">>)               -> true;
known_op(<<"aggregate">>)          -> true;
known_op(<<"filter">>)             -> true;
known_op(<<"project">>)            -> true;
known_op(<<"antijoin">>)           -> true;
known_op(<<"circuit_access">>)     -> true;
known_op(<<"fixpoint">>)           -> true;
known_op(_)                        -> false.

parse_node_arg(Arg) when is_binary(Arg) ->
    Trimmed = trim(Arg),
    case Trimmed of
        <<>> -> {error, empty_arg};
        _ ->
            case binary:match(Trimmed, <<":">>) of
                {Pos, 1} when Pos > 0 ->
                    KeyBin = binary:part(Trimmed, 0, Pos),
                    ValBin = trim(binary:part(Trimmed, Pos + 1, byte_size(Trimmed) - Pos - 1)),
                    Key = binary_to_atom(KeyBin, utf8),
                    Val = parse_kw_val(ValBin),
                    case ValBin of
                        <<"[", _/binary>> ->
                            Inner = extract_brackets(ValBin),
                            Items = parse_string_list(Inner),
                            {Key, Items};
                        _ ->
                            {Key, Val}
                    end;
                _ ->
                    case binary:match(Trimmed, <<".">>) of
                        {DotPos, 1} when DotPos > 0 ->
                            VarBin = binary:part(Trimmed, 0, DotPos),
                            FieldBin = binary:part(Trimmed, DotPos + 1,
                                                    byte_size(Trimmed) - DotPos - 1),
                            {circuit_access, VarBin, FieldBin};
                        nomatch ->
                            case Trimmed of
                                <<"\"", _/binary>> -> {string, dequote(Trimmed)};
                                _ -> {var, Trimmed}
                            end
                    end
            end
    end.

parse_kw_val(ValBin) ->
    Trimmed = trim(ValBin),
    case binary:match(Trimmed, <<".">>) of
        {DotPos, 1} when DotPos > 0 ->
            VarBin = binary:part(Trimmed, 0, DotPos),
            FieldBin = binary:part(Trimmed, DotPos + 1,
                                    byte_size(Trimmed) - DotPos - 1),
            {circuit_access, VarBin, FieldBin};
        _ ->
            case Trimmed of
                <<"\"", _/binary>> -> dequote(Trimmed);
                _ -> {var, Trimmed}
            end
    end.

%%====================================================================
%% Arg parsing
%%====================================================================

parse_args_raw(Bin) ->
    Tokens = split_top(trim_trailing_comma(Bin), <<",">>),
    [trim(T) || T <- Tokens, trim(T) =/= <<>>].

parse_args(Bin) ->
    Tokens = split_top(trim_trailing_comma(Bin), <<",">>),
    lists:filtermap(fun(Tok) ->
        case trim(Tok) of
            <<>> -> false;
            T -> {true, T}
        end
    end, Tokens).

%%====================================================================
%% Type annotations
%%====================================================================

parse_type_ann(Name, TypeBin, St, Rest) ->
    Type = parse_type_spec(trim(TypeBin), St#st.line),
    case Type of
        {stream, _} -> ok;
        _ -> parse_error(St#st.line,
            "expected stream(...) type, got: ~s", [trim(TypeBin)])
    end,
    Spec = #gdbsp_typespec{
        name = Name,
        spec = {type, Type},
        line = St#st.line
    },
    parse_lines(Rest, St#st{typespecs = [Spec | St#st.typespecs]}).

parse_type_spec(Bin, Line) ->
    Trimmed = trim(Bin),
    case Trimmed of
        <<"stream(", _/binary>> ->
            case extract_parens(Trimmed) of
                {closed, Inner} ->
                    {stream, parse_type_spec(trim(Inner), Line)};
                {open, _} ->
                    parse_error(Line, "expected ')' after stream type")
            end;
        <<"struct(", _/binary>> ->
            {_, Inner} = extract_parens(Trimmed),
            Fields = parse_struct_fields(Inner, Line),
            {struct, Fields, exact};
        <<"array(", _/binary>> ->
            {_, Inner} = extract_parens(Trimmed),
            Args = split_top(Inner, <<",">>),
            case Args of
                [ElemType] -> {array, parse_type_spec(ElemType, Line), varsize};
                [ElemType | Dims] ->
                    IntDims = lists:map(fun(D) -> binary_to_integer(trim(D)) end, Dims),
                    {array, parse_type_spec(ElemType, Line),
                     case IntDims of [N] -> N; _ -> IntDims end}
            end;
        <<"map(", _/binary>> ->
            {_, Inner} = extract_parens(Trimmed),
            [K, V] = split_top(Inner, <<",">>),
            {map, parse_type_spec(K, Line), parse_type_spec(V, Line)};
        <<"closure(", _/binary>> ->
            {_, Inner} = extract_parens(Trimmed),
            parse_closure_type(closure, Inner, Line);
        <<"result_equivalent_closure(", _/binary>> ->
            {_, Inner} = extract_parens(Trimmed),
            parse_closure_type(result_equivalent_closure, Inner, Line);
        _ ->
            parse_scalar_type(Trimmed, Line)
    end.

parse_struct_fields(Bin, Line) ->
    Pairs = split_top(Bin, <<",">>),
    lists:foldl(fun(Pair, Acc) ->
        TrimPair = trim(Pair),
        case binary:split(TrimPair, <<":">>) of
            [Key0, ValType] ->
                Key = case trim(Key0) of
                    <<"\"", _/binary>> = Q -> dequote(Q);
                    K -> K
                end,
                maps:put(Key, parse_type_spec(trim(ValType), Line), Acc);
            _ ->
                %% Might be "key: type" vs "key:type" 
                case binary:match(TrimPair, <<":">>) of
                    {Pos, 1} ->
                        Key0 = binary:part(TrimPair, 0, Pos),
                        ValType = trim(binary:part(TrimPair, Pos + 1, byte_size(TrimPair) - Pos - 1)),
                        Key = case trim(Key0) of
                            <<"\"", _/binary>> = Q -> dequote(Q);
                            K -> K
                        end,
                        maps:put(Key, parse_type_spec(ValType, Line), Acc);
                    nomatch ->
                        parse_error(Line, "invalid struct field: ~s", [Pair])
                end
        end
    end, #{}, Pairs).

parse_scalar_type(<<"i8">>, _) -> i8;
parse_scalar_type(<<"i16">>, _) -> i16;
parse_scalar_type(<<"i32">>, _) -> i32;
parse_scalar_type(<<"i64">>, _) -> i64;
parse_scalar_type(<<"u8">>, _) -> u8;
parse_scalar_type(<<"u16">>, _) -> u16;
parse_scalar_type(<<"u32">>, _) -> u32;
parse_scalar_type(<<"u64">>, _) -> u64;
parse_scalar_type(<<"integer">>, _) -> integer;
parse_scalar_type(<<"f32">>, _) -> f32;
parse_scalar_type(<<"f64">>, _) -> f64;
parse_scalar_type(<<"numeric">>, _) -> numeric;
parse_scalar_type(<<"bytes">>, _) -> bytes;
parse_scalar_type(<<"bits">>, _) -> bits;
parse_scalar_type(<<"json">>, _) -> json;
parse_scalar_type(<<"dynamic">>, _) -> dynamic;
parse_scalar_type(<<"date">>, _) -> date;
parse_scalar_type(<<"time">>, _) -> time;
parse_scalar_type(<<"timestamp">>, _) -> timestamp;
parse_scalar_type(<<"timestamp_with_timezone">>, _) -> timestamp_with_timezone;
parse_scalar_type(<<"interval">>, _) -> interval;
parse_scalar_type(<<"string_with_encoding">>, _) -> string_with_encoding;
parse_scalar_type(Bin, Line) when is_binary(Bin) ->
    case Bin of
        <<"string(\"UTF-8\")">> -> {string, <<"UTF-8">>};
        <<"string(", _/binary>> ->
            {_, Inner} = extract_parens(Bin),
            {string, dequote(trim(Inner))};
        <<"enum(", _/binary>> ->
            {_, Inner} = extract_parens(Bin),
            {enum, parse_string_list(Inner)};
        <<"bytes(", _/binary>> ->
            {_, Inner} = extract_parens(Bin),
            {bytes, binary_to_integer(trim(Inner))};
        <<"bits(", _/binary>> ->
            {_, Inner} = extract_parens(Bin),
            {bits, binary_to_integer(trim(Inner))};
        <<"numeric(", _/binary>> ->
            {_, Inner} = extract_parens(Bin),
            [P, S] = split_top(Inner, <<",">>),
            {numeric, binary_to_integer(trim(P)), binary_to_integer(trim(S))};
        <<"optional(", _/binary>> ->
            {_, Inner} = extract_parens(Bin),
            {optional, parse_type_spec(Inner, Line)};
        _ ->
            case is_type_var(Bin) of
                true -> Bin;
                false -> parse_error(Line, "unknown type: ~s", [Bin])
            end
    end.

is_type_var(Bin) when byte_size(Bin) > 0 ->
    First = binary:first(Bin),
    First >= $A andalso First =< $Z.

parse_closure_type(Kind, Bin, Line) ->
    Trimmed = trim(Bin),
    case Trimmed of
        <<"(", _/binary>> ->
            {_, Inner} = extract_parens(Trimmed),
            [ParamsBin, RetBin] = split_top(Inner, <<"->">>),
            Ret = parse_type_spec(trim(RetBin), Line),
            case trim(ParamsBin) of
                <<>> ->
                    {Kind, [], Ret};
                ParamsTrimmed ->
                    ParamTypes = lists:map(fun(P) ->
                        parse_type_spec(trim(P), Line)
                    end, split_top(ParamsTrimmed, <<",">>)),
                    {Kind, [{<<>>, PT} || PT <- ParamTypes], Ret}
            end;
        _ ->
            parse_error(Line, "expected '(' in closure type")
    end.

%%====================================================================
%% Function declarations
%%====================================================================

parse_fn_decl(Name, Kind, Rest0, St, Rest) ->
    Clean = trim(Rest0),
    case Clean of
        <<"(", _/binary>> ->
            {ParamsBin, RetBin} = split_fn_sig(Clean, St#st.line),
            Ret = parse_type_spec(trim(RetBin), St#st.line),
            case Kind of
                aggregate_function ->
                    Spec = #gdbsp_typespec{
                        name = Name,
                        spec = {aggregate_function,
                                [parse_type_spec(trim(ParamsBin), St#st.line)],
                                Ret},
                        line = St#st.line
                    },
                    parse_lines(Rest, St#st{typespecs = [Spec | St#st.typespecs]});
                function when ParamsBin =:= <<>> ->
                    Spec = #gdbsp_typespec{
                        name = Name,
                        spec = {function, [], Ret},
                        line = St#st.line
                    },
                    parse_lines(Rest, St#st{typespecs = [Spec | St#st.typespecs]});
                function ->
                    Params = lists:map(fun(P) ->
                        parse_type_spec(trim(P), St#st.line)
                    end, split_top(ParamsBin, <<",">>)),
                    Spec = #gdbsp_typespec{
                        name = Name,
                        spec = {function, Params, Ret},
                        line = St#st.line
                    },
                    parse_lines(Rest, St#st{typespecs = [Spec | St#st.typespecs]})
            end;
        _ ->
            parse_error(St#st.line, "expected '(' in function declaration")
    end.

split_fn_sig(<<"(", Rest/binary>>, Line) ->
    split_fn_sig(Rest, 0, <<>>, Line).

split_fn_sig(<<>>, _Depth, _Acc, Line) ->
    parse_error(Line, "invalid function declaration");
split_fn_sig(<<$\\, C, Rest/binary>>, D, Acc, Line) ->
    split_fn_sig(Rest, D, <<Acc/binary, $\\, C>>, Line);
split_fn_sig(<<$", Rest/binary>>, D, Acc, Line) ->
    split_fn_sig_quote(Rest, D, <<Acc/binary, $">>, Line);
split_fn_sig(<<$(, Rest/binary>>, D, Acc, Line) ->
    split_fn_sig(Rest, D + 1, <<Acc/binary, $(>>, Line);
split_fn_sig(<<$), Rest/binary>>, D, Acc, Line) when D > 0 ->
    split_fn_sig(Rest, D - 1, <<Acc/binary, $)>>, Line);
split_fn_sig(<<$), Rest/binary>>, 0, Acc, Line) ->
    Rest1 = trim_left(Rest),
    case Rest1 of
        <<"->", $\s, Ret0/binary>> ->
            Ret = strip_trailing_paren(trim(Ret0)),
            {trim_right(Acc), Ret};
        <<"->", Ret0/binary>> ->
            Ret = strip_trailing_paren(trim(Ret0)),
            {trim_right(Acc), Ret};
        _ ->
            parse_error(Line, "invalid function declaration")
    end;
split_fn_sig(<<C, Rest/binary>>, D, Acc, Line) ->
    split_fn_sig(Rest, D, <<Acc/binary, C>>, Line).

split_fn_sig_quote(<<$", Rest/binary>>, D, Acc, Line) ->
    split_fn_sig(Rest, D, <<Acc/binary, $">>, Line);
split_fn_sig_quote(<<$\\, C, Rest/binary>>, D, Acc, Line) ->
    split_fn_sig_quote(Rest, D, <<Acc/binary, $\\, C>>, Line);
split_fn_sig_quote(<<C, Rest/binary>>, D, Acc, Line) ->
    split_fn_sig_quote(Rest, D, <<Acc/binary, C>>, Line).

strip_trailing_paren(Bin) ->
    Trimmed = trim_right(Bin),
    case byte_size(Trimmed) > 0 andalso binary:last(Trimmed) =:= $) of
        true -> binary:part(Trimmed, 0, byte_size(Trimmed) - 1);
        false -> Trimmed
    end.

%%====================================================================
%% String helpers
%%====================================================================

trim(Bin) when is_binary(Bin) ->
    trim_left(trim_right(Bin)).

trim_left(<<>>) -> <<>>;
trim_left(<<$\s, Rest/binary>>) -> trim_left(Rest);
trim_left(<<$\t, Rest/binary>>) -> trim_left(Rest);
trim_left(Bin) -> Bin.

trim_right(<<>>) -> <<>>;
trim_right(Bin) ->
    Size = byte_size(Bin),
    case binary:at(Bin, Size - 1) of
        $\s -> trim_right(binary:part(Bin, 0, Size - 1));
        $\t -> trim_right(binary:part(Bin, 0, Size - 1));
        $\r -> trim_right(binary:part(Bin, 0, Size - 1));
        $\n -> trim_right(binary:part(Bin, 0, Size - 1));
        _ -> Bin
    end.

dequote(Bin) ->
    Trimmed = trim(Bin),
    Size = byte_size(Trimmed),
    if Size >= 2 ->
        case {binary:first(Trimmed), binary:last(Trimmed)} of
            {$", $"} -> binary:part(Trimmed, 1, Size - 2);
            _ -> Trimmed
        end;
       true -> Trimmed
    end.

split_top(Bin, Sep) ->
    split_top(Bin, Sep, 0, 0, [], <<>>).

split_top(<<>>, _Sep, _Depth, _Quote, Acc, Buf) ->
    case trim(Buf) of
        <<>> -> lists:reverse(Acc);
        _ -> lists:reverse([Buf | Acc])
    end;
split_top(<<C, Rest/binary>>, Sep, Depth, Quote, Acc, Buf) ->
    SepSize = byte_size(Sep),
    case {Depth, Quote} of
        {0, 0} when C =:= $" ->
            split_top(Rest, Sep, 0, 1, Acc, <<Buf/binary, C>>);
        {0, 1} when C =:= $" ->
            split_top(Rest, Sep, 0, 0, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $[ ->
            split_top(Rest, Sep, Depth + 1, Quote, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $] ->
            split_top(Rest, Sep, Depth - 1, Quote, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $( ->
            split_top(Rest, Sep, Depth + 1, Quote, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $) ->
            split_top(Rest, Sep, Depth - 1, Quote, Acc, <<Buf/binary, C>>);
        {0, 0} ->
            Remaining = <<C, Rest/binary>>,
            case binary:longest_common_prefix([Remaining, Sep]) of
                L when L >= SepSize ->
                    <<_:SepSize/binary, AfterSep/binary>> = Remaining,
                    case trim(Buf) of
                        <<>> -> split_top(AfterSep, Sep, 0, 0, Acc, <<>>);
                        BufTrim -> split_top(AfterSep, Sep, 0, 0, [BufTrim | Acc], <<>>)
                    end;
                _ ->
                    split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
            end;
        _ ->
            split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
    end.

parse_string_list(Bin) ->
    Items = split_top(trim(Bin), <<",">>),
    lists:map(fun(I) -> dequote(trim(I)) end, Items).

%%====================================================================
%% Error handling
%%====================================================================

parse_error(Line, Fmt) ->
    throw({parse_error, Line, iolist_to_binary(io_lib:format(Fmt, []))}).

parse_error(Line, Fmt, Args) ->
    throw({parse_error, Line, iolist_to_binary(io_lib:format(Fmt, Args))}).
