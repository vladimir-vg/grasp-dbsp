-ifndef(GDBSP_PARSE_HRL).
-define(GDBSP_PARSE_HRL, true).

-include("gdbsp_parse_expr.hrl").

-record(gdbsp_node_def, {
    name   :: binary(),    % node name
    op     :: atom(),      % operator name
    args   :: list(),      % arguments (node refs are binaries, strings are binaries)
    line   :: pos_integer()
}).

-record(gdbsp_typespec, {
    name   :: binary(),    % declared name
    spec   :: {type, term()}
            | {function, [term()], #{binary() => term()}, term()}
            | {aggregate_function, [term()], #{binary() => term()}, term()},
    line   :: pos_integer()
}).

-record(gdbsp_circuit_def, {
    name   :: binary(),       % circuit name
    params :: #{atom() => binary()},  % #{Keyword => InternalName}
    body   :: [#gdbsp_node_def{}]
}).

-record(gdbsp_fn_def, {
    name    :: binary(),
    params  :: [{pos, binary()} | {kw, binary(), binary()}],
    body    :: parse_expr(),
    line    :: pos_integer()
}).

-record(gdbsp_program, {
    nodes      :: [#gdbsp_node_def{}],
    typespecs  :: [#gdbsp_typespec{}],
    circuits   :: [#gdbsp_circuit_def{}],
    fn_defs    :: [#gdbsp_fn_def{}]
}).

-endif.
