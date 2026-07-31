%%%-------------------------------------------------------------------
%%% @doc Shared string/binary helpers used across the compiler.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_string_util).

-export([trim/1, trim_left/1, trim_right/1, dequote/1,
         split_top/2, parse_string_list/1]).

trim(<<>>) -> <<>>;
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
                        BufTrim -> split_top(AfterSep, Sep, 0, 0,
                                             [BufTrim | Acc], <<>>)
                    end;
                _ ->
                    split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
            end;
        _ ->
            split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
    end.

parse_string_list(Bin) ->
    Trimmed = trim(Bin),
    case Trimmed of
        <<"[", _/binary>> ->
            Inner = binary:part(Trimmed, 1, byte_size(Trimmed) - 2),
            Tokens = split_top(Inner, <<",">>),
            [dequote(trim(T)) || T <- Tokens, trim(T) =/= <<>>];
        _ -> [Trimmed]
    end.
