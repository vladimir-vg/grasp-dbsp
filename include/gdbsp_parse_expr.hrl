%%%-------------------------------------------------------------------
%%% @doc Parse expression type — syntactic representation preserving
%%% operator structure, dot chains, and literal forms before desugaring.
%%% @end
%%%-------------------------------------------------------------------

-ifndef(GDBSP_PARSE_EXPR_HRL).
-define(GDBSP_PARSE_EXPR_HRL, true).

-type const_tag() :: integer | decimal | float | string | bits | absent.

-type parse_expr() ::
    {var,           pos_integer(), binary()} |
    {const,         pos_integer(), term(), const_tag(), term(), term()} |
    {symbol,        pos_integer(), binary()} |
    {binop,         pos_integer(), atom(), parse_expr(), parse_expr()} |
    {unop,          pos_integer(), atom(), parse_expr()} |
    {call,          pos_integer(), binary(), [kv_arg()]} |
    {agg,           pos_integer(), binary(), [kv_arg()]} |
    {dict_literal,  pos_integer(), [kv_arg()], parse_expr() | undefined} |
    {array_literal, pos_integer(), [array_elem()]} |
    {subscript,     pos_integer(), parse_expr(), subscript_spec()} |
    {dot_access,    pos_integer(), parse_expr(), binary()}.

-type kv_arg() :: {kv, binary(), parse_expr()} | parse_expr().

-type array_elem() :: parse_expr() | {rest, pos_integer(), binary()}.

-type subscript_spec() ::
    {index, parse_expr()} |
    {slice, parse_expr() | undefined, parse_expr() | undefined, parse_expr() | undefined}.

-endif.
