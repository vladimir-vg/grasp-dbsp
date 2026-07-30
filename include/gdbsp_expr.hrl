%%%-------------------------------------------------------------------
%%% @doc Unified expression type — the canonical expression representation
%%% for the Grasp language. Used by gg-storage (runtime) and grasp
%%% (compiler) to represent expression trees.
%%%
%%% All expressions carry typed values as leaf nodes. No locations,
%%% no JSON maps — pure Erlang terms.
%%% @end
%%%-------------------------------------------------------------------

-ifndef(GDBSP_EXPR_HRL).
-define(GDBSP_EXPR_HRL, true).

-include("gdbsp_type.hrl").

-type expr() ::
    {value, gdbsp_column_type(), term()} |                                     %% typed leaf value
    {arg, binary()} |                                                    %% function argument reference
    {call,  binary(), [expr()], #{binary() => expr()}} |               %% function call (pos, kw)
    {agg,   binary(), [expr()], #{binary() => expr()}} |              %% aggregate call
    {get,   expr(), [expr()]} |                                        %% subscript: obj[k1][k2]...
    {slice, expr(),                                                    %% container
                expr() | undefined,                                    %% start (undefined = beginning)
                expr() | undefined,                                    %% stop  (undefined = end)
                expr() | undefined}.                                   %% step  (undefined = 1)

-endif.
