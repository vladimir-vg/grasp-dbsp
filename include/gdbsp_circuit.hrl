-ifndef(GDBSP_CIRCUIT_HRL).
-define(GDBSP_CIRCUIT_HRL, true).

-type node_id() :: pos_integer().

-type operator() ::
    {source, binary()} |
    {output, binary()} |
    {map, map()} |
    {filter, map()} |
    {flat_map, map()} |
    {neg} |
    {plus} |
    {map_index, map()} |
    {join, map()} |
    {distinct} |
    {aggregate, binary()} |
    {integrate} |
    {integrate, map()} |
    {differentiate} |
    {delay} |
    {antijoin, [binary()], [binary()]}.

-record(circuit_node, {
    id       :: node_id(),
    op       :: operator(),
    inputs   :: [node_id()],
    meta     :: map()
}).

-record(circuit_graph, {
    next_id = 1 :: pos_integer(),
    nodes   = #{} :: #{node_id() => #circuit_node{}},
    schemas = #{} :: #{node_id() => [binary()]}
}).

-endif.
