%%%-------------------------------------------------------------------
%%% @doc gdbsp command-line front-end.
%%%
%%% Escript entry point (main/1) plus a pure parse_args/1 and the three
%%% subcommand runners: validate, run, serve.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_cli).

-export([main/1]).
-export([parse_args/1]).
-export([run/1, validate/1, serve/1]).
-export([load_error_msg/1, compile_error_msg/1]).

%%====================================================================
%% main
%%====================================================================

-spec main([string()]) -> no_return().
main(Args) ->
    case parse_args(Args) of
        {ok, Spec} ->
            case dispatch(Spec) of
                ok -> halt(0);
                {error, Msg} ->
                    io:format(standard_error, "gdbsp: ~s~n", [Msg]),
                    halt(1)
            end;
        {error, Reason} ->
            io:format(standard_error, "gdbsp: ~s~n", [format_arg_error(Reason)]),
            halt(1)
    end.

dispatch(#{command := validate} = Spec) -> validate(Spec);
dispatch(#{command := run} = Spec) -> run(Spec);
dispatch(#{command := serve} = Spec) -> serve(Spec).

%%====================================================================
%% Argument parsing
%%====================================================================

-spec parse_args([string()]) -> {ok, map()} | {error, term()}.
parse_args([]) ->
    {error, usage};
parse_args([Cmd | Rest]) ->
    case Cmd of
        "validate" -> parse_validate(Rest, []);
        "run" -> parse_run(Rest, #{inputs => #{}, outputs => [], sources => []});
        "serve" -> parse_serve(Rest, #{outputs => [], sources => [],
                                       listen => {"127.0.0.1", 8080}});
        _ -> {error, {unknown_command, list_to_binary(Cmd)}}
    end.

parse_validate([], Sources) when Sources =/= [] ->
    {ok, #{command => validate, sources => lists:reverse(Sources)}};
parse_validate([], []) ->
    {error, no_sources};
parse_validate([Arg | Rest], Sources) ->
    case is_option(Arg) of
        true -> {error, {unknown_option, list_to_binary(Arg)}};
        false -> parse_validate(Rest, [Arg | Sources])
    end.

parse_run([], #{outputs := []}) ->
    {error, no_outputs};
parse_run([], #{sources := []}) ->
    {error, no_sources};
parse_run([], #{outputs := Outputs, inputs := Inputs, sources := Sources}) ->
    {ok, #{command => run,
           sources => lists:reverse(Sources),
           inputs => Inputs,
           outputs => lists:reverse(Outputs)}};
parse_run(["--output" | Rest], #{outputs := Outputs} = Acc) ->
    case Rest of
        [Spec | Rest2] ->
            case split_once(Spec, $=) of
                {Name, Dest} ->
                    parse_run(Rest2, Acc#{outputs :=
                        [{list_to_binary(Name), Dest} | Outputs]});
                error ->
                    {error, {invalid_output, list_to_binary(Spec)}}
            end;
        [] ->
            {error, missing_output_value}
    end;
parse_run(["--input" | Rest], #{inputs := Inputs} = Acc) ->
    case Rest of
        [Spec | Rest2] ->
            case split_once(Spec, $=) of
                {Table, File} ->
                    parse_run(Rest2, Acc#{inputs :=
                        maps:put(list_to_binary(Table), File, Inputs)});
                error ->
                    {error, {invalid_input, list_to_binary(Spec)}}
            end;
        [] ->
            {error, missing_input_value}
    end;
parse_run([Arg | Rest], #{sources := Sources} = Acc) ->
    case is_option(Arg) of
        true -> {error, {unknown_option, list_to_binary(Arg)}};
        false -> parse_run(Rest, Acc#{sources := [Arg | Sources]})
    end.

parse_serve([], #{outputs := []}) ->
    {error, no_outputs};
parse_serve([], #{sources := []}) ->
    {error, no_sources};
parse_serve([], #{outputs := Outputs, listen := Listen, sources := Sources}) ->
    {ok, #{command => serve,
           sources => lists:reverse(Sources),
           outputs => lists:reverse(Outputs),
           listen => Listen}};
parse_serve(["--output" | Rest], #{outputs := Outputs} = Acc) ->
    case Rest of
        [Name | Rest2] ->
            parse_serve(Rest2, Acc#{outputs := [list_to_binary(Name) | Outputs]});
        [] ->
            {error, missing_output_value}
    end;
parse_serve(["--listen" | Rest], Acc) ->
    case Rest of
        [Addr | Rest2] ->
            case parse_listen(Addr) of
                {ok, Listen} -> parse_serve(Rest2, Acc#{listen := Listen});
                error -> {error, {invalid_listen, list_to_binary(Addr)}}
            end;
        [] ->
            {error, missing_listen_value}
    end;
parse_serve([Arg | Rest], #{sources := Sources} = Acc) ->
    case is_option(Arg) of
        true -> {error, {unknown_option, list_to_binary(Arg)}};
        false -> parse_serve(Rest, Acc#{sources := [Arg | Sources]})
    end.

split_once(Str, Char) ->
    case string:split(Str, [Char]) of
        [Before, After] -> {Before, After};
        _ -> error
    end.

parse_listen(Addr) ->
    case split_once(Addr, $:) of
        {Ip, PortStr} ->
            case catch list_to_integer(PortStr) of
                Port when is_integer(Port), Port > 0, Port =< 65535 ->
                    {ok, {Ip, Port}};
                _ -> error
            end;
        error -> error
    end.

is_option([$-, $- | _]) -> true;
is_option([$- | _]) -> true;
is_option(_) -> false.

%%====================================================================
%% validate
%%====================================================================

-spec validate(map()) -> ok | {error, iolist()}.
validate(Spec) ->
    Sources = maps:get(sources, Spec),
    case gdbsp_loader:load_sources(Sources) of
        {error, Reason} -> {error, load_error_msg(Reason)};
        {ok, Prog} ->
            case gdbsp_loader:compile(Prog, [], true) of
                {error, Reason} -> {error, compile_error_msg(Reason)};
                {ok, Compiled} ->
                    {ok, Rt} = gdbsp_runtime:start(Compiled),
                    gdbsp_runtime:stop(Rt),
                    ok
            end
    end.

%%====================================================================
%% run
%%====================================================================

-spec run(map()) -> ok | {error, iolist()}.
run(Spec) ->
    Sources = maps:get(sources, Spec),
    Inputs = maps:get(inputs, Spec),
    Outputs = maps:get(outputs, Spec),
    OutputNames = [Name || {Name, _Dest} <- Outputs],
    case gdbsp_loader:load_sources(Sources) of
        {error, Reason} -> {error, load_error_msg(Reason)};
        {ok, Prog} ->
            case gdbsp_loader:compile(Prog, OutputNames, true) of
                {error, Reason} -> {error, compile_error_msg(Reason)};
                {ok, Compiled} ->
                    SourceTypes = maps:get(source_types, Compiled),
                    case check_inputs(Inputs, SourceTypes) of
                        {error, _} = E -> E;
                        ok ->
                            {ok, Rt} = gdbsp_runtime:start(Compiled),
                            try
                                run_offline(Rt, Inputs, Outputs)
                            after
                                gdbsp_runtime:stop(Rt)
                            end
                    end
            end
    end.

check_inputs(Inputs, SourceTypes) ->
    maps:fold(
        fun(Table, _File, ok) ->
            case maps:is_key(Table, SourceTypes) of
                true -> ok;
                false -> {error, ["unknown input table: ", Table]}
            end;
           (_Table, _File, Err) -> Err
        end, ok, Inputs).

run_offline(Rt, Inputs, Outputs) ->
    SourceTypes = gdbsp_runtime:source_types(Rt),
    case feed_inputs(Rt, Inputs, SourceTypes) of
        {error, _} = E -> E;
        ok ->
            case open_outputs(Outputs) of
                {error, _} = E -> E;
                {ok, Handles} ->
                    try
                        write_headers(Rt, Outputs, Handles),
                        write_epochs(Rt, Outputs, Handles)
                    after
                        close_outputs(Handles)
                    end
            end
    end.

feed_inputs(Rt, Inputs, SourceTypes) ->
    maps:fold(
        fun(Table, File, ok) ->
            {_Node, Type} = maps:get(Table, SourceTypes),
            case read_input_file(File, Type) of
                {ok, Rows} ->
                    ok = gdbsp_runtime:feed(Rt, Table, Rows),
                    ok = gdbsp_runtime:mark_exhausted(Rt, Table),
                    ok;
                {error, Reason} ->
                    {error, ["input ", Table, " (", File, "): ", Reason]}
            end;
           (_Table, _File, Err) -> Err
        end, ok, Inputs).

write_epochs(Rt, Outputs, Handles) ->
    case gdbsp_runtime:step(Rt) of
        exhausted -> ok;
        idle -> ok;
        {ok, Epoch} ->
            ok = gdbsp_runtime:await_epoch(Rt, Epoch),
            lists:foreach(
                fun({Name, _Dest}) ->
                    Lines = gdbsp_runtime:lines(Rt, Name, Epoch),
                    write_lines(maps:get(Name, Handles), Lines)
                end, Outputs),
            write_epochs(Rt, Outputs, Handles)
    end.

open_outputs(Outputs) ->
    open_outputs(Outputs, #{}).

open_outputs([], Acc) ->
    {ok, Acc};
open_outputs([{Name, Dest} | Rest], Acc) ->
    case open_dest(Dest) of
        {ok, Handle} -> open_outputs(Rest, Acc#{Name => Handle});
        {error, Reason} -> {error, ["cannot open output ", Dest, ": ",
                                    file:format_error(Reason)]}
    end.

open_dest("-") -> {ok, stdout};
open_dest(Path) ->
    case file:open(Path, [write]) of
        {ok, Io} -> {ok, {file, Io}};
        {error, Reason} -> {error, Reason}
    end.

close_outputs(Handles) ->
    maps:foreach(
        fun(_Name, stdout) -> ok;
           (_Name, {file, Io}) -> file:close(Io)
        end, Handles).

write_lines(Handle, Lines) ->
    lists:foreach(fun(Line) -> write_line(Handle, Line) end, Lines).

write_line(stdout, Json) ->
    io:format("~s~n", [gdbsp_jsonl:encode_line(Json)]);
write_line({file, Io}, Json) ->
    io:format(Io, "~s~n", [gdbsp_jsonl:encode_line(Json)]).

%% Write the header line, which was emitted during open via the runtime.
write_headers(Rt, Outputs, Handles) ->
    lists:foreach(
        fun({Name, _Dest}) ->
            Header = gdbsp_runtime:header(Rt, Name),
            write_line(maps:get(Name, Handles), Header)
        end, Outputs).

%%====================================================================
%% JSONL input reading
%%====================================================================

read_input_file(File, Type) ->
    case file:read_file(File) of
        {error, Reason} -> {error, ["cannot read input ", File, ": ",
                                    file:format_error(Reason)]};
        {ok, Bin} ->
            case gdbsp_jsonl:decode_body(Type, Bin) of
                {ok, Rows} ->
                    {ok, Rows};
                {error, {Line, Reason}} ->
                    {error, ["line ", integer_to_list(Line), ": ",
                             gdbsp_jsonl:format_reason(Reason)]}
            end
    end.

%%====================================================================
%% serve (implemented in gdbsp_http)
%%====================================================================

-spec serve(map()) -> ok | {error, iolist()}.
serve(Spec) ->
    gdbsp_http:serve(Spec).

%%====================================================================
%% Error formatting
%%====================================================================

format_arg_error(usage) ->
    "usage: gdbsp <validate|run|serve> ...";
format_arg_error({unknown_command, Cmd}) ->
    ["unknown command: ", Cmd];
format_arg_error(no_sources) ->
    "no source files given";
format_arg_error(no_outputs) ->
    "no --output given";
format_arg_error({invalid_output, Spec}) ->
    ["invalid --output (expected NAME=DEST): ", Spec];
format_arg_error({invalid_input, Spec}) ->
    ["invalid --input (expected TABLE=FILE): ", Spec];
format_arg_error({invalid_listen, Addr}) ->
    ["invalid --listen (expected IP:PORT): ", Addr];
format_arg_error(missing_output_value) ->
    "missing value after --output";
format_arg_error(missing_input_value) ->
    "missing value after --input";
format_arg_error(missing_listen_value) ->
    "missing value after --listen";
format_arg_error({unknown_option, Arg}) ->
    ["unknown option: ", Arg].

load_error_msg({parse_error, File, {Line, Msg}}) ->
    ["parse error in ", File, ":", integer_to_list(Line), ": ",
     iolist_to_binary(io_lib:format("~p", [Msg]))];
load_error_msg({read_error, File, Reason}) ->
    ["cannot read ", File, ": ", file:format_error(Reason)].

compile_error_msg({unknown_output, Name}) ->
    ["unknown output: ", Name];
compile_error_msg({fixpoint_error, {_Line, Msg}}) ->
    ["fixpoint_error: ", iolist_to_binary(Msg)];
compile_error_msg(Reason) ->
    ["compile_error: ", iolist_to_binary(io_lib:format("~p", [Reason]))].
