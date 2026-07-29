-module(gdbsp_ct_helpers).

-export([check_pass/2, check_violation/2, check_violation_reason/2, check_throw/2]).

check_pass(_, _) -> pass.
check_violation(_, _) -> violation.
check_violation_reason(_, _) -> {violation, test_reason}.
check_throw(_, _) -> throw(test_exception).
