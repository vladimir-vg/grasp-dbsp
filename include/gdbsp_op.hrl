-ifndef(GDBSP_OP_HRL).
-define(GDBSP_OP_HRL, true).

-type op_action() :: {send, pid(), term()} | {error, term()}.

-endif.
