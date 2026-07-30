-ifndef(GDBSP_LOWERED_HRL).
-define(GDBSP_LOWERED_HRL, true).

-type lnode_id() :: binary().

-type lnode_tag() :: binary().

-type fixpoint_hash() :: binary().

-type fixpoint_param_kind() :: base | self_ref.

-type fixpoint_param_info() :: #{
    kind     := fixpoint_param_kind(),
    label    := lnode_tag(),
    input    := lnode_id(),
    body_out := lnode_id()
}.

-type fixpoint_info() :: #{
    circuit_name := binary(),
    tags         := [lnode_tag()],
    params       := #{binary() => fixpoint_param_info()}
}.

-record(lnode, {
    id     :: lnode_id(),
    op     :: atom(),
    inputs :: [lnode_id()],
    args   :: list(),
    tags   :: [lnode_tag()],
    type   :: term() | undefined
}).

-record(lowered_graph, {
    nodes     = #{} :: #{lnode_id() => #lnode{}},
    tag_map   = #{} :: #{lnode_tag() => lnode_id()},
    fixpoints = #{} :: #{fixpoint_hash() => fixpoint_info()}
}).

-endif.
