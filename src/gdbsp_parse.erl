%%%-------------------------------------------------------------------
%%% @doc Token-based parser for .gdbsp source.
%%% Consumes the token stream from gdbsp_lexer and produces #gdbsp_program{}.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_parse).

-export([parse/2, parse_string/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_type.hrl").

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
    case gdbsp_lexer:string(Bin) of
        {ok, Tokens} ->
            try
                {Nodes, TSs, Circuits, FnDefs} = parse_declarations(Tokens, [], [], [], []),
                Prog = #gdbsp_program{
                    nodes     = lists:reverse(Nodes),
                    typespecs = lists:reverse(TSs),
                    circuits  = lists:reverse(Circuits),
                    fn_defs   = lists:reverse(FnDefs)
                },
                {ok, Prog}
            catch
                throw:{parse_error, Line, Msg} ->
                    {error, {Line, Msg}}
            end;
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Top-level — collect declarations
%%====================================================================

parse_declarations([], Nodes, TSs, Circuits, FnDefs) ->
    {Nodes, TSs, Circuits, FnDefs};
parse_declarations([{newline, _} | Rest], Nodes, TSs, Circuits, FnDefs) ->
    parse_declarations(Rest, Nodes, TSs, Circuits, FnDefs);
parse_declarations([{indent, _} | Rest], Nodes, TSs, Circuits, FnDefs) ->
    parse_declarations(Rest, Nodes, TSs, Circuits, FnDefs);
parse_declarations([{identifier, _L, <<"circuit">>} | Rest], Nodes, TSs, Circuits, FnDefs) ->
    {Def, Rest2} = parse_circuit_def(Rest),
    parse_declarations(Rest2, Nodes, TSs, [Def | Circuits], FnDefs);
parse_declarations([{identifier, Line, FirstName} | Rest], Nodes, TSs, Circuits, FnDefs) ->
    {Name, Rest2} = parse_compound_name(FirstName, Rest),
    case Rest2 of
        [{double_colon, _} | Rest3] ->
            {TS, Rest4} = parse_typespec(Name, Rest3),
            parse_declarations(Rest4, Nodes, [TS | TSs], Circuits, FnDefs);
        [{walrus, _} | Rest3] ->
            case Rest3 of
                [{identifier, _, <<"function">>}, {'(', _} | _] ->
                    {Fn, Rest4} = parse_fn_def(Name, Line, Rest3),
                    parse_declarations(Rest4, Nodes, TSs, Circuits, [Fn | FnDefs]);
                _ ->
                    {Node, Rest4} = parse_node_def(Name, Line, Rest3),
                    parse_declarations(Rest4, [Node | Nodes], TSs, Circuits, FnDefs)
            end;
        _ ->
            throw({parse_error, token_line(hd(Rest2)), <<"unrecognized declaration">>})
    end;
parse_declarations([T | _], _Nodes, _TSs, _Circuits, _FnDefs) ->
    throw({parse_error, token_line(T), <<"unrecognized declaration">>}).

%%--------------------------------------------------------------------
%% Compound name parsing — consumes identifier (. identifier)*
%%--------------------------------------------------------------------

parse_compound_name(Name, [{dot, _}, T | Rest]) ->
    Next = token_name(T),
    parse_compound_name(<<Name/binary, ".", Next/binary>>, Rest);
parse_compound_name(Name, Tokens) ->
    {Name, Tokens}.

token_name({identifier, _, N}) -> N;
token_name({not_keyword, _}) -> <<"not">>;
token_name({and_keyword, _}) -> <<"and">>;
token_name({or_keyword, _}) -> <<"or">>;
token_name({N, _}) when is_atom(N) -> atom_to_binary(N, utf8);
token_name(T) -> token_name2(T).

token_name2({N, _, _}) when is_atom(N) -> atom_to_binary(N, utf8);
token_name2(_) -> <<>>.

%%====================================================================
%% Node definitions
%%====================================================================

parse_node_def(Name, Line, Tokens) ->
    case Tokens of
        [{identifier, _, VarName}, {dot, _} | Rest] ->
            parse_member_access_node(Name, Line, VarName, Rest);
        [{identifier, _, OpName}, {'(', _} | Rest] ->
            parse_node_def_with_op(Name, Line, OpName, Rest);
        [{identifier, _, VarName} | Rest] ->
            Node = #gdbsp_node_def{
                name = Name, op = plus, args = [{var, VarName}],
                line = Line
            },
            {Node, skip_to_decl(Rest)};
        [{string, _, _} = T | Rest] ->
            Node = #gdbsp_node_def{
                name = Name, op = plus, args = [{string, token_val(T)}],
                line = Line
            },
            {Node, skip_to_decl(Rest)};
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"expected '(' or argument after :=">>})
    end.

parse_member_access_node(Name, Line, Var, [{identifier, _, Field} | Rest]) ->
    Node = #gdbsp_node_def{
        name = Name, op = member_access,
        args = [{var, Var}, {var, Field}],
        line = Line
    },
    {Node, skip_to_decl(Rest)};
parse_member_access_node(_Name, _Line, _Var, Tokens) ->
    throw({parse_error, token_line(hd(Tokens)),
           <<"invalid circuit access">>}).

parse_node_def_with_op(Name, Line, OpName, Tokens) ->
    OpAtom = case known_op(OpName) of
        true  -> binary_to_atom(OpName, utf8);
        false -> circuit_call
    end,
    case OpAtom of
        fixpoint ->
            parse_fixpoint_node(Name, Line, Tokens);
        _ ->
            parse_regular_node(Name, Line, OpAtom, OpName, Tokens)
    end.

parse_regular_node(Name, Line, OpAtom, OpName, Tokens) ->
    {Args, Rest} = collect_node_args(Tokens, []),
    FinalArgs = case OpAtom of
        circuit_call -> [{var, OpName} | Args];
        _ -> Args
    end,
    Node = #gdbsp_node_def{
        name = Name, op = OpAtom, args = FinalArgs,
        line = Line
    },
    {Node, Rest}.

%%--------------------------------------------------------------------
%% Fixpoint
%%--------------------------------------------------------------------

parse_fixpoint_node(Name, Line, Tokens) ->
    {Args, Rest} = collect_fixpoint_args(Tokens, []),
    Node = #gdbsp_node_def{
        name = Name, op = fixpoint, args = Args,
        line = Line
    },
    {Node, Rest}.

collect_fixpoint_args(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | Rest] -> {lists:reverse(Acc), skip_to_decl(Rest)};
        [] -> throw({parse_error, 0, <<"unexpected end of fixpoint args">>});
        Toks ->
            case Toks of
                [{identifier, _, CName}, {'(', _} | Rest] when Acc =:= [] ->
                    collect_fixpoint_kwargs(Rest, [{var, CName} | Acc]);
                [{identifier, _, Kw}, {':', _} | Rest] when Acc =/= [] ->
                    {Val, Rest2} = parse_fixpoint_kw_val(Rest),
                    collect_fixpoint_kwargs(Rest2,
                        [{binary_to_atom(Kw, utf8), Val} | Acc]);
                _ ->
                    throw({parse_error, token_line(hd(Toks)),
                           <<"expected keyword arg in fixpoint">>})
            end
    end.

collect_fixpoint_kwargs(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | Rest] ->
            Rest2 = skip_newlines(Rest),
            {')', _} = expect(Rest2, ')'),
            {lists:reverse(Acc), skip_to_decl(tl(Rest2))};
        [] -> throw({parse_error, 0, <<"unexpected end of fixpoint args">>});
        [{',', _} | Rest] -> collect_fixpoint_args(Rest, Acc);
        Toks -> collect_fixpoint_args(Toks, Acc)
    end.

parse_fixpoint_kw_val([{identifier, _, V}, {'(', _} | Rest]) ->
    {CallArgs, Rest2} = collect_inline_call_args(Rest, []),
    {{expr, {call, V, CallArgs}}, Rest2};
parse_fixpoint_kw_val(Tokens) ->
    case Tokens of
        [{identifier, _, V}, {dot, _}, {identifier, _, F} | Rest] ->
            {{member_access, V, F}, Rest};
        [{identifier, _, V} | Rest] -> {{var, V}, Rest};
        [{string, _, _} = T | Rest] -> {{string, token_val(T)}, Rest};
        _ -> throw({parse_error, token_line(hd(Tokens)),
                    <<"expected value after ':' in fixpoint arg">>})
    end.

%%--------------------------------------------------------------------
%% Node args collection
%%--------------------------------------------------------------------

collect_node_args(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | Rest] -> {lists:reverse(Acc), skip_to_decl(Rest)};
        [] -> {lists:reverse(Acc), []};
        Toks ->
            case Toks of
                [{',', _} | Rest] ->
                    collect_node_args(Rest, Acc);
                [{'[', _} | Rest] ->
                    {Items, Rest2} = collect_bracket_list(Rest, []),
                    collect_node_args(Rest2, [Items | Acc]);
                [{identifier, _, KwName}, {':', _} | Rest] ->
                    {KwVal, Rest2} = parse_kw_arg(Rest),
                    collect_node_args(Rest2,
                        [{binary_to_atom(KwName, utf8), KwVal} | Acc]);
                [{identifier, _, VarName}, {'(', _} | Rest] ->
                    {CallArgs, Rest2} = collect_inline_call_args(Rest, []),
                    collect_node_args(Rest2,
                        [{expr, {call, VarName, CallArgs}} | Acc]);
                [{identifier, _, VarName}, {dot, _}, {identifier, _, Field} | Rest] ->
                    collect_node_args(Rest,
                        [{member_access, VarName, Field} | Acc]);
                [{identifier, _, VarName} | Rest] ->
                    collect_node_args(Rest, [{var, VarName} | Acc]);
                [{string, _, _} = T | Rest] ->
                    collect_node_args(Rest, [{string, token_val(T)} | Acc]);
                _ ->
                    throw({parse_error, token_line(hd(Toks)),
                           <<"unexpected token in node args">>})
            end
    end.

collect_inline_call_args(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | Rest] -> {lists:reverse(Acc), Rest};
        [] -> {lists:reverse(Acc), []};
        Toks ->
            case Toks of
                [{',', _} | Rest] ->
                    collect_inline_call_args(Rest, Acc);
                [{identifier, _, VarName}, {dot, _}, {identifier, _, F} | Rest] ->
                    collect_inline_call_args(Rest,
                        [{member_access, VarName, F} | Acc]);
                [{identifier, _, VarName} | Rest] ->
                    collect_inline_call_args(Rest, [{var, VarName} | Acc]);
                [{string, _, _} = T | Rest] ->
                    collect_inline_call_args(Rest, [{string, token_val(T)} | Acc]);
                _ ->
                    throw({parse_error, token_line(hd(Toks)),
                           <<"unexpected token in inline call args">>})
            end
    end.

parse_kw_arg([{'[', _} | Rest]) ->
    {Items, Rest2} = collect_bracket_list(Rest, []),
    {Items, Rest2};
parse_kw_arg(Tokens) ->
    case Tokens of
        [{identifier, _, V}, {dot, _}, {identifier, _, F} | Rest] ->
            {{member_access, V, F}, Rest};
        [{identifier, _, V} | Rest] -> {{var, V}, Rest};
        [{string, _, _} = T | Rest] -> {token_val(T), Rest};
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                    <<"expected value after ':' in node kwarg">>})
    end.

collect_bracket_list(Tokens, Acc) ->
    case Tokens of
        [{']', _} | Rest] -> {lists:reverse(Acc), Rest};
        [{',', _} | Rest] -> collect_bracket_list(Rest, Acc);
        [{'[', _} | Rest] ->
            {Items, Rest2} = collect_bracket_list(Rest, []),
            collect_bracket_list(Rest2, [Items | Acc]);
        [{string, _, V} | Rest] ->
            collect_bracket_list(Rest, [V | Acc]);
        [{identifier, _, V} | Rest] ->
            collect_bracket_list(Rest, [V | Acc]);
        _ -> throw({parse_error, token_line(hd(Tokens)),
                    <<"expected ']' or value in bracket list">>})
    end.

%%====================================================================
%% Typespecs
%%====================================================================

parse_typespec(Name, Tokens) ->
    case Tokens of
        [{identifier, _, <<"stream">>}, {'(', _} | Rest] ->
            {Type, Rest2} = parse_type(Rest),
            {')', _} = expect(Rest2, ')'),
            Spec = #gdbsp_typespec{
                name = Name, spec = {type, {stream, Type}},
                line = token_line(hd(Tokens))},
            {Spec, skip_to_decl(tl(Rest2))};
        [{identifier, _, <<"function">>}, {'(', _} | Rest] ->
            parse_fn_typespec(Name, function, Rest);
        [{identifier, _, <<"aggregate_function">>}, {'(', _} | Rest] ->
            parse_fn_typespec(Name, aggregate_function, Rest);
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"unknown type: expected stream/function/aggregate_function">>})
    end.

parse_fn_typespec(Name, Kind, Tokens) ->
    case Tokens of
        [{'(', _} | Rest] ->
            {PosTypes, KwMap, Rest2} = parse_fn_type_params(Rest, [], []),
            {arrow, _} = expect(Rest2, arrow),
            {RetType, Rest3} = parse_type(tl(Rest2)),
            {')', _} = expect(Rest3, ')'),
            Spec = #gdbsp_typespec{
                name = Name,
                spec = {Kind, PosTypes, maps:from_list(KwMap), RetType},
                kw_order = [K || {K, _} <- KwMap],
                line = token_line(hd(Tokens))
            },
            {Spec, skip_to_decl(tl(Rest3))};
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"expected '(' in function declaration">>})
    end.

parse_fn_type_params(Tokens, PosAcc, KwAcc) ->
    case Tokens of
        [{')', _} | Rest] -> {lists:reverse(PosAcc), lists:reverse(KwAcc), Rest};
        [] -> throw({parse_error, 0, <<"unexpected end of fn type params">>});
        [{',', _} | Rest] -> parse_fn_type_params(Rest, PosAcc, KwAcc);
        _ ->
            case is_kw_type_param(Tokens) of
                {true, Key, Rest} ->
                    {Type, Rest2} = parse_type(Rest),
                    parse_fn_type_params(Rest2, PosAcc, [{Key, Type} | KwAcc]);
                false when KwAcc =:= [] ->
                    {Type, Rest2} = parse_type(Tokens),
                    parse_fn_type_params(Rest2, [Type | PosAcc], KwAcc);
                false ->
                    throw({parse_error, token_line(hd(Tokens)),
                           <<"keyword params must come after positional params">>})
            end
    end.

is_kw_type_param([{string, _, _}, {':', _} | _] = Tokens) ->
    {true, token_val(hd(Tokens)), tl(tl(Tokens))};
is_kw_type_param(_) ->
    false.

%%====================================================================
%% Type parsing (token-based)
%%====================================================================

parse_type(Tokens) ->
    case Tokens of
        [{identifier, _, <<"struct">>}, {'(', _} | Rest] ->
            parse_struct_type(Rest);
        [{identifier, _, <<"array">>}, {'(', _} | Rest] ->
            parse_array_type(Rest);
        [{identifier, _, <<"map">>}, {'(', _} | Rest] ->
            parse_map_type(Rest);
        [{identifier, _, <<"optional">>}, {'(', _} | Rest] ->
            {T, Rest2} = parse_type(Rest),
            {')', _} = expect(Rest2, ')'),
            {{optional, T}, tl(Rest2)};
        [{identifier, _, <<"closure">>}, {'(', _} | Rest] ->
            parse_closure_type(closure, Rest);
        [{identifier, _, <<"result_equivalent_closure">>}, {'(', _} | Rest] ->
            parse_closure_type(result_equivalent_closure, Rest);
        [{identifier, _, <<"stream">>}, {'(', _} | Rest] ->
            {T, Rest2} = parse_type(Rest),
            {')', _} = expect(Rest2, ')'),
            {{stream, T}, tl(Rest2)};
        [{identifier, _, <<"string">>}, {'(', _}, {string, _, Enc}, {')', _} | Rest] ->
            {{string, Enc}, Rest};
        [{identifier, _, <<"enum">>}, {'(', _} | Rest] ->
            {Values, Rest2} = parse_enum_values(Rest, []),
            {{enum, lists:usort(Values)}, Rest2};
        [{identifier, _, <<"bytes">>}, {'(', _}, {integer_literal, _, N}, {')', _} | Rest] ->
            {{bytes, N}, Rest};
        [{identifier, _, <<"bits">>}, {'(', _}, {integer_literal, _, N}, {')', _} | Rest] ->
            {{bits, N}, Rest};
        [{identifier, _, <<"numeric">>}, {'(', _},
         {integer_literal, _, P}, {',', _}, {integer_literal, _, S}, {')', _} | Rest] ->
            {{numeric, P, S}, Rest};
        [{identifier, _, Name} | Rest] ->
            {parse_scalar_type(Name, token_line(hd(Tokens))), Rest};
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"expected type">>})
    end.

parse_enum_values(Tokens, Acc) ->
    case Tokens of
        [{')', _} | Rest] -> {lists:reverse(Acc), Rest};
        [{',', _} | Rest] -> parse_enum_values(Rest, Acc);
        [{string, _, V} | Rest] -> parse_enum_values(Rest, [V | Acc]);
        _ -> throw({parse_error, token_line(hd(Tokens)),
                    <<"expected string value or ')' in enum type">>})
    end.

parse_struct_type(Tokens) ->
    {Fields, Rest} = parse_struct_fields(Tokens, #{}),
    {{struct, Fields, exact}, Rest}.

parse_struct_fields(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | Rest] -> {Acc, Rest};
        [] -> {Acc, []};
        [{',', _} | Rest] -> parse_struct_fields(Rest, Acc);
        [{string, _, _}, {':', _} | _] ->
            Key = token_val(hd(Tokens)),
            {T, Rest} = parse_type(tl(tl(Tokens))),
            parse_struct_fields(Rest, Acc#{Key => T});
        [{identifier, _, FName}, {':', _} | Rest] ->
            {T, Rest2} = parse_type(Rest),
            parse_struct_fields(Rest2, Acc#{FName => T});
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"invalid struct field">>})
    end.

parse_array_type(Tokens) ->
    {ElemType, Rest} = parse_type(Tokens),
    case skip_newlines(Rest) of
        [{')', _} | Rest2] ->
            {{array, ElemType, varsize}, Rest2};
        [{',', _} | Rest2] ->
            case Rest2 of
                [{integer_literal, _, Dim} | Rest3] ->
                    {Dims, Rest4} = parse_array_dims(Rest3, [Dim]),
                    ArrayType = case Dims of
                        [N] -> {array, ElemType, N};
                        _   -> {array, ElemType, Dims}
                    end,
                    {ArrayType, Rest4};
                _ ->
                    throw({parse_error, token_line(hd(Rest2)),
                           <<"expected integer dimension">>})
            end;
        _ ->
            throw({parse_error, token_line(hd(Rest)),
                   <<"expected ')' or dimensions in array type">>})
    end.

parse_array_dims(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | Rest] -> {lists:reverse(Acc), Rest};
        [{',', _} | Rest] ->
            case skip_newlines(Rest) of
                [{integer_literal, _, Dim} | Rest2] ->
                    parse_array_dims(Rest2, [Dim | Acc]);
                _ ->
                    throw({parse_error, token_line(hd(Rest)),
                           <<"expected integer dimension">>})
            end;
        [{integer_literal, _, Dim} | Rest] ->
            parse_array_dims(Rest, [Dim | Acc]);
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"expected ')' or ',' or integer dimension">>})
    end.

parse_map_type(Tokens) ->
    {K, Rest} = parse_type(Tokens),
    {',', _} = expect(Rest, ','),
    {V, Rest2} = parse_type(tl(Rest)),
    {')', _} = expect(Rest2, ')'),
    {{map, K, V}, tl(Rest2)}.

parse_closure_type(Kind, Tokens) ->
    case Tokens of
        [{'(', _} | Rest] ->
            {PosTypes, KwMap, Rest2} = parse_fn_type_params(Rest, [], []),
            {arrow, _} = expect(Rest2, arrow),
            {RetType, Rest3} = parse_type(tl(Rest2)),
            {')', _} = expect(Rest3, ')'),
            Params = [{undefined, T} || T <- PosTypes] ++ KwMap,
            {{Kind, Params, RetType}, tl(Rest3)};
        _ ->
            %% zero-param closure: closure(() -> T)
            _ = expect(Tokens, '('),
            _ = expect(tl(Tokens), ')'),
            {arrow, _} = expect(tl(tl(Tokens)), '->'),
            {RetType, Rest} = parse_type(tl(tl(tl(Tokens)))),
            {')', _} = expect(Rest, ')'),
            {{Kind, [], RetType}, tl(Rest)}
    end.

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
parse_scalar_type(Name, Line) ->
    case is_type_var(Name) of
        true -> {type_var, Name};
        false ->
            throw({parse_error, Line,
                   iolist_to_binary(["unknown type: ", Name])})
    end.

is_type_var(Bin) when byte_size(Bin) > 0 ->
    First = binary:first(Bin),
    First >= $A andalso First =< $Z.

%%====================================================================
%% Circuit definitions
%%====================================================================

parse_circuit_def([{identifier, _, Name}, {'(', _} | Rest]) ->
    {Params, Rest2} = parse_circuit_params(Rest, #{}),
    {')', _} = expect(Rest2, ')'),
    {':', _} = expect(tl(Rest2), ':'),
    Tokens3 = tl(tl(Rest2)),
    {BodyNodes, Rest3} = parse_circuit_body(Tokens3, []),
    Def = #gdbsp_circuit_def{name = Name, params = Params, body = BodyNodes},
    {Def, Rest3};
parse_circuit_def(Tokens) ->
    throw({parse_error, token_line(hd(Tokens)),
           <<"expected '(' after circuit name">>}).

parse_circuit_params(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{')', _} | _] -> {Acc, Tokens};
        [{',', _} | Rest] -> parse_circuit_params(Rest, Acc);
        [{identifier, _, Key}, {':', _}, {identifier, _, Val} | Rest] ->
            KeyAtom = binary_to_atom(Key, utf8),
            parse_circuit_params(Rest, Acc#{KeyAtom => Val});
        _ ->
            throw({parse_error, token_line(hd(Tokens)),
                   <<"expected 'key: internal' in circuit params">>})
    end.

parse_circuit_body(Tokens, Acc) ->
    case skip_newlines(Tokens) of
        [{body_line, _} | Rest] ->
            case Rest of
                [{identifier, BLine, BName}, {walrus, _} | Rest2] ->
                    {Node, Rest3} = parse_node_def(BName, BLine, Rest2),
                    parse_circuit_body(Rest3, [Node | Acc]);
                _ ->
                    throw({parse_error, token_line(hd(Rest)),
                           <<"invalid node in circuit body">>})
            end;
        _ ->
            {lists:reverse(Acc), Tokens}
    end.

%%====================================================================
%% Function definitions
%%====================================================================

parse_fn_def(Name, Line, [{identifier, _, <<"function">>}, {'(', _}, {'(', _} | ParamTokens]) ->
    {Params, Rest2} = parse_fn_params(ParamTokens, []),
    {arrow, _} = expect(Rest2, arrow),
    {Body, Rest3} = parse_expr(tl(Rest2)),
    {')', _} = expect(Rest3, ')'),
    Fn = #gdbsp_fn_def{
        name = Name, params = lists:reverse(Params), body = Body, line = Line
    },
    {Fn, skip_to_decl(tl(Rest3))}.

parse_fn_params([{')', _} | Rest], Acc) ->
    {Acc, Rest};
parse_fn_params([{arrow, _} | _], Acc) ->
    {Acc, []};
parse_fn_params([{identifier, _, N}, {':', _} | Rest], Acc) ->
    case Rest of
        [{identifier, _, V} | Rest2] when V =/= <<"function">> ->
            parse_fn_params(Rest2, [{kw, N, V} | Acc]);
        [{',', _} | Rest2] ->
            parse_fn_params(Rest2, [{kw, N, N} | Acc]);
        _ ->
            parse_fn_params(Rest, [{kw, N, N} | Acc])
    end;
parse_fn_params([{identifier, _, N}, {',', _} | Rest], Acc) ->
    parse_fn_params(Rest, [{pos, N} | Acc]);
parse_fn_params([{identifier, _, N} | Rest], Acc) ->
    parse_fn_params(Rest, [{pos, N} | Acc]);
parse_fn_params([{',', _} | Rest], Acc) ->
    parse_fn_params(Rest, Acc);
parse_fn_params(Tokens, _Acc) ->
    throw({parse_error, token_line(hd(Tokens)),
           <<"invalid parameter in function definition">>}).

%%====================================================================
%% Expressions — precedence climbing
%%====================================================================

parse_expr(Tokens) -> parse_or(Tokens).

%% ── Boolean: or ─────────────────────────────────────────────────────

parse_or(Tokens) ->
    {LHS, Rest} = parse_and(Tokens),
    parse_or_rest(LHS, Rest).

parse_or_rest(LHS, [{or_keyword, _} | Rest]) ->
    {RHS, Rest2} = parse_and(Rest),
    parse_or_rest({binop, 0, 'or', LHS, RHS}, Rest2);
parse_or_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Boolean: and ────────────────────────────────────────────────────

parse_and(Tokens) ->
    {LHS, Rest} = parse_cmp(Tokens),
    parse_and_rest(LHS, Rest).

parse_and_rest(LHS, [{and_keyword, _} | Rest]) ->
    {RHS, Rest2} = parse_cmp(Rest),
    parse_and_rest({binop, 0, 'and', LHS, RHS}, Rest2);
parse_and_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Comparison (no chaining) ────────────────────────────────────────

parse_cmp(Tokens) ->
    {LHS, Rest} = parse_grouped_binary(Tokens),
    case Rest of
        [{Op, _} | Rest2] when Op =:= '='; Op =:= '!='; Op =:= '>';
                                Op =:= '<'; Op =:= '>='; Op =:= '<=' ->
            {RHS, Rest3} = parse_grouped_binary(Rest2),
            {{binop, 0, Op, LHS, RHS}, Rest3};
        _ -> {LHS, Rest}
    end.

%% ── Grouped binary (two-phase dispatch) ──────────────────────────────

parse_grouped_binary(Tokens) ->
    {LHS, Rest} = parse_prefix(Tokens),
    parse_grouped_binary_rest(LHS, Rest).

parse_grouped_binary_rest(LHS, [{'++', _} | Rest]) ->
    {RHS, Rest2} = parse_prefix(Rest),
    parse_concat_rest({binop, 0, '++', LHS, RHS}, Rest2);
parse_grouped_binary_rest(LHS, [{Op, _} | _] = Tokens)
    when Op =:= '|'; Op =:= '^'; Op =:= '&' ->
    parse_bitwise_rest(LHS, Tokens);
parse_grouped_binary_rest(LHS, [{Op, _} | Rest])
    when Op =:= '<<'; Op =:= '>>'; Op =:= '<<<'; Op =:= '>>>' ->
    {RHS, Rest2} = parse_prefix(Rest),
    {{binop, 0, Op, LHS, RHS}, Rest2};
parse_grouped_binary_rest(LHS, [{Op, _} | Rest]) when Op =:= '+'; Op =:= '-' ->
    {RHS, Rest2} = parse_mul(Rest),
    parse_add_rest({binop, 0, Op, LHS, RHS}, Rest2);
parse_grouped_binary_rest(LHS, [{Op, _} | Rest]) when Op =:= '*'; Op =:= '/'; Op =:= '%' ->
    {RHS, Rest2} = parse_prefix(Rest),
    parse_mul_rest({binop, 0, Op, LHS, RHS}, Rest2);
parse_grouped_binary_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Concatenation ───────────────────────────────────────────────────

parse_concat_rest(LHS, [{'++', _} | Rest]) ->
    {RHS, Rest2} = parse_prefix(Rest),
    parse_concat_rest({binop, 0, '++', LHS, RHS}, Rest2);
parse_concat_rest(_LHS, [{Op, _} | _] = Rest)
    when Op =:= '|'; Op =:= '^'; Op =:= '&';
         Op =:= '<<'; Op =:= '>>'; Op =:= '<<<'; Op =:= '>>>';
         Op =:= '+'; Op =:= '-'; Op =:= '*'; Op =:= '/'; Op =:= '%' ->
    throw({parse_error, token_line(hd(Rest)),
           iolist_to_binary(["cannot mix '++' with ", atom_to_list(Op)])});
parse_concat_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Bitwise — same group, different ops error ───────────────────────

parse_bitwise_rest(LHS, [{Op, _} | Rest])
    when Op =:= '|'; Op =:= '^'; Op =:= '&' ->
    {RHS, Rest2} = parse_prefix(Rest),
    parse_bitwise_rest({binop, 0, Op, LHS, RHS}, Rest2);
parse_bitwise_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Arithmetic: +, - ────────────────────────────────────────────────

parse_add_rest(LHS, [{Op, _} | Rest]) when Op =:= '+'; Op =:= '-' ->
    {RHS, Rest2} = parse_mul(Rest),
    parse_add_rest({binop, 0, Op, LHS, RHS}, Rest2);
parse_add_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Arithmetic: *, /, % ─────────────────────────────────────────────

parse_mul(Tokens) ->
    {LHS, Rest} = parse_prefix(Tokens),
    parse_mul_rest(LHS, Rest).

parse_mul_rest(LHS, [{Op, _} | Rest]) when Op =:= '*'; Op =:= '/'; Op =:= '%' ->
    {RHS, Rest2} = parse_prefix(Rest),
    parse_mul_rest({binop, 0, Op, LHS, RHS}, Rest2);
parse_mul_rest(LHS, Rest) -> {LHS, Rest}.

%% ── Prefix / unary ──────────────────────────────────────────────────

parse_prefix([{not_keyword, _} | Rest]) ->
    {E, Rest2} = parse_prefix(Rest),
    {{unop, 0, 'not', E}, Rest2};
parse_prefix([{'-', _} | Rest]) ->
    {E, Rest2} = parse_prefix(Rest),
    {{unop, 0, '-', E}, Rest2};
parse_prefix([{'~', _} | Rest]) ->
    {E, Rest2} = parse_prefix(Rest),
    {{unop, 0, '~', E}, Rest2};
parse_prefix(Tokens) -> parse_atomic(Tokens).

%% ── Atomic expressions ──────────────────────────────────────────────

parse_atomic(Tokens) ->
    {E, R} = parse_atomic_core(Tokens),
    {E2, R2} = parse_subscript(E, R),
    parse_dot_chain(E2, R2).

parse_dot_chain(E, [{dot, _}, {identifier, _, Field} | Rest]) ->
    parse_dot_chain({dot_access, 0, E, Field}, Rest);
parse_dot_chain(E, Rest) -> {E, Rest}.

parse_atomic_core([{identifier, L, Name}, {'(', _} | Rest]) ->
    {Args, Rest2} = parse_fn_call_args(Rest, []),
    {')', _} = expect(Rest2, ')'),
    {{call, L, Name, lists:reverse(Args)}, tl(Rest2)};
parse_atomic_core([{identifier, L, <<"true">>} | Rest]) ->
    {{symbol, L, <<"true">>}, Rest};
parse_atomic_core([{identifier, L, <<"false">>} | Rest]) ->
    {{symbol, L, <<"false">>}, Rest};
parse_atomic_core([{identifier, L, <<"null">>} | Rest]) ->
    {{symbol, L, <<"null">>}, Rest};
parse_atomic_core([{identifier, L, <<"absent">>} | Rest]) ->
    {{const, L, absent, absent, undefined, undefined}, Rest};
parse_atomic_core([{identifier, L, Name}, {dot, _} = DotTok | Rest]) ->
    case try_parse_dotted_call(L, Name, Rest) of
        {ok, CallExpr, Rest2} -> {CallExpr, Rest2};
        not_call -> {{var, L, Name}, [DotTok | Rest]}
    end;
parse_atomic_core([{identifier, L, Name} | Rest]) ->
    {{var, L, Name}, Rest};
parse_atomic_core([{integer_literal, L, Val} | Rest]) ->
    {{const, L, Val, integer, undefined, undefined}, Rest};
parse_atomic_core([{decimal_literal, L, Val} | Rest]) ->
    {{const, L, Val, decimal, undefined, undefined}, Rest};
parse_atomic_core([{float_literal, L, Val} | Rest]) ->
    {{const, L, Val, float, undefined, undefined}, Rest};
parse_atomic_core([{bits_literal, L, Val} | Rest]) ->
    {{const, L, Val, bits, undefined, undefined}, Rest};
parse_atomic_core([{string, L, Val} | Rest]) ->
    {{const, L, Val, string, undefined, undefined}, Rest};
parse_atomic_core([{'(', _} | Rest]) ->
    {Expr, Rest2} = parse_expr(Rest),
    {')', _} = expect(Rest2, ')'),
    {Expr, tl(Rest2)};
parse_atomic_core([{'{', _} | Rest]) -> parse_dict(Rest);
parse_atomic_core([{'[', _} | Rest]) -> parse_array(Rest);
parse_atomic_core(Tokens) ->
    throw({parse_error, token_line(hd(Tokens)),
           <<"expected expression">>}).

%% ── Dotted function call (e.g. std.string_upper(...)) ───────────────
%%
%% A dotted identifier path immediately followed by '(' is a function
%% call whose name is the dotted path. Otherwise the leading identifier
%% is a variable and the dots are field accesses (handled by
%% parse_dot_chain/2).

try_parse_dotted_call(L, Name, Rest) ->
    case Rest of
        [{identifier, _, Seg} | More] ->
            try_parse_dotted_call_cont(L, <<Name/binary, ".", Seg/binary>>, More);
        _ ->
            not_call
    end.

try_parse_dotted_call_cont(L, Dotted, [{dot, _}, {identifier, _, Seg} | More]) ->
    try_parse_dotted_call_cont(L, <<Dotted/binary, ".", Seg/binary>>, More);
try_parse_dotted_call_cont(L, Dotted, [{'(', _} | CallArgs]) ->
    {Args, Rest2} = parse_fn_call_args(CallArgs, []),
    {')', _} = expect(Rest2, ')'),
    {ok, {call, L, Dotted, lists:reverse(Args)}, tl(Rest2)};
try_parse_dotted_call_cont(_L, _Dotted, _More) ->
    not_call.

%% ── Function call arguments (mixed pos / kw) ────────────────────────

parse_fn_call_args([{')', _} | _] = Tokens, Acc) ->
    {Acc, Tokens};
parse_fn_call_args(Tokens, Acc) ->
    case Tokens of
        [{',', _} | Rest] ->
            parse_fn_call_args(Rest, Acc);
        [{identifier, _, Key}, {':', _} | Rest] ->
            {Val, Rest2} = parse_expr(Rest),
            parse_fn_call_args(Rest2, [{kv, Key, Val} | Acc]);
        [{string, _, Key}, {':', _} | Rest] ->
            {Val, Rest2} = parse_expr(Rest),
            parse_fn_call_args(Rest2, [{kv, Key, Val} | Acc]);
        _ ->
            {Val, Rest2} = parse_expr(Tokens),
            parse_fn_call_args(Rest2, [Val | Acc])
    end.

%% ── Subscript ───────────────────────────────────────────────────────

parse_subscript(E, [{'[', _} | Rest]) ->
    {Spec, Rest2} = parse_subscript_args(Rest),
    {']', _} = expect(Rest2, ']'),
    parse_subscript({subscript, 0, E, Spec}, tl(Rest2));
parse_subscript(E, Rest) -> {E, Rest}.

parse_subscript_args(Tokens) ->
    case parse_expr(Tokens) of
        {Expr, [{':', _} | Rest]} ->
            parse_slice_rest(Expr, Rest);
        {Expr, Rest} ->
            {{index, Expr}, Rest}
    end.

parse_slice_rest(Start, Tokens) ->
    case Tokens of
        [{':', _} | Rest] ->
            {{slice, Start, undefined, undefined}, Rest};
        [{']', _} | _] ->
            {{slice, Start, undefined, undefined}, Tokens};
        _ ->
            {Stop, Rest} = parse_expr(Tokens),
            case Rest of
                [{':', _} | Rest2] ->
                    {Step, Rest3} = parse_expr(Rest2),
                    {{slice, Start, Stop, Step}, Rest3};
                _ ->
                    {{slice, Start, Stop, undefined}, Rest}
            end
    end.

%% ── Dict literal ────────────────────────────────────────────────────

parse_dict(Tokens) ->
    {KwArgs, Rest, RestVar} = parse_dict_entries(Tokens, []),
    case Rest of
        [{'}', _} | Rest2] ->
            {{dict_literal, 0, lists:reverse(KwArgs), RestVar}, skip_newlines(Rest2)};
        _ ->
            {{dict_literal, 0, lists:reverse(KwArgs), RestVar}, skip_newlines(Rest)}
    end.

parse_dict_entries([{'}', _} | _] = Tokens, Acc) -> {Acc, Tokens, undefined};
parse_dict_entries([{double_star, _}, {identifier, _, Var} | Rest], Acc) ->
    {Acc, Rest, {var, 0, Var}};
parse_dict_entries([{double_star, _}, {'}', _} | _] = Tokens, Acc) ->
    {Acc, Tokens, undefined};
parse_dict_entries([{identifier, _, Key}, {':', _} | Rest], Acc) ->
    {Val, Rest2} = parse_expr(Rest),
    parse_dict_entries(Rest2, [{kv, Key, Val} | Acc]);
parse_dict_entries([{string, _, Key}, {':', _} | Rest], Acc) ->
    {Val, Rest2} = parse_expr(Rest),
    parse_dict_entries(Rest2, [{kv, Key, Val} | Acc]);
parse_dict_entries([{',', _} | Rest], Acc) ->
    parse_dict_entries(Rest, Acc);
parse_dict_entries(Tokens, _Acc) ->
    throw({parse_error, token_line(hd(Tokens)),
           <<"expected key: value in dict literal">>}).

%% ── Array literal ───────────────────────────────────────────────────

parse_array(Tokens) ->
    parse_array_elems(skip_newlines(Tokens), []).

parse_array_elems([{']', _} | Rest], Acc) ->
    {{array_literal, 0, lists:reverse(Acc)}, skip_newlines(Rest)};
parse_array_elems([{'*', _}, {identifier, L, Var} | Rest], Acc) ->
    parse_array_elems(Rest, [{rest, L, Var} | Acc]);
parse_array_elems([{',', _} | Rest], Acc) ->
    parse_array_elems(Rest, Acc);
parse_array_elems(Tokens, Acc) ->
    {Expr, Rest} = parse_expr(Tokens),
    parse_array_elems(Rest, [Expr | Acc]).

%%====================================================================
%% Helpers
%%====================================================================

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
known_op(<<"order">>)              -> true;
known_op(<<"filter">>)             -> true;
known_op(<<"project">>)            -> true;
known_op(<<"antijoin">>)           -> true;
known_op(<<"member_access">>)     -> true;
known_op(<<"fixpoint">>)           -> true;
known_op(<<"empty">>)              -> true;
known_op(_)                        -> false.

skip_newlines(Tokens) ->
    case Tokens of
        [{newline, _} | Rest] -> skip_newlines(Rest);
        [{indent, _} | Rest] -> skip_newlines(Rest);
        _ -> Tokens
    end.

skip_to_decl(Tokens) ->
    case Tokens of
        [{newline, _} | Rest] -> Rest;
        [{indent, _} | Rest] -> Rest;
        [] -> [];
        _ -> Tokens
    end.

expect(Tokens, Tag) ->
    case Tokens of
        [{Tag, _} = T | _] -> T;
        [] -> throw({parse_error, 0, iolist_to_binary(
                      ["expected '", atom_to_list(Tag), "'"])});
        [T | _] ->
            throw({parse_error, token_line(T),
                   iolist_to_binary(["expected '", atom_to_list(Tag), "'"])})
    end.

token_line({_, Line}) when is_integer(Line) -> Line;
token_line({_, Line, _}) when is_integer(Line) -> Line;
token_line({_, Line, _, _}) when is_integer(Line) -> Line;
token_line(_) -> 0.

token_val({_, _, Val}) -> Val.
