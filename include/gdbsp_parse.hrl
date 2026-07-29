-ifndef(GDBSP_PARSE_HRL).
-define(GDBSP_PARSE_HRL, true).

-record(gdbsp_node_def, {
    name   :: binary(),    % node name
    op     :: atom(),      % operator name
    args   :: list(),      % arguments (node refs are binaries, strings are binaries)
    line   :: pos_integer()
}).

-record(gdbsp_typespec, {
    name   :: binary(),    % declared name
    spec   :: {type, term()}
            | {function, [term()], term()}
            | {aggregate_function, [term()], term()},
    line   :: pos_integer()
}).

-record(gdbsp_program, {
    nodes      :: [#gdbsp_node_def{}],
    typespecs  :: [#gdbsp_typespec{}]
}).

-endif.
