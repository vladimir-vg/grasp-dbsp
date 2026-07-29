-module(gdbsp_hash).

-export([md5/1]).

-spec md5(binary()) -> string().
md5(Data) ->
    hex(crypto:hash(md5, Data)).

hex(Bin) ->
    binary_to_list(<< <<(hex_digit(N div 16)), (hex_digit(N rem 16))>> || <<N>> <= Bin >>).

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.
