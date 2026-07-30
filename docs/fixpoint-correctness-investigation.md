# Fixpoint Correctness: Investigation of Pre-existing Test Failures

Date: 2026-07-30
Status: diagnosed — fixes proposed

---

## 1. Overview

Two pre-existing test failures were investigated: `e2e_operators_8`
(await_done_timeout) and `e2e_fixpoint_selfref` (weight 2 instead of 1).

---

## 2. e2e_operators_8 — Race Condition in Test Harness

### 2.1 Symptom

```
{await_done_timeout, {epoch, 0}}
```

The output collector never receives an `epoch_done` barrier for epoch 0.
The test is `delay + plus` with source `"data"` and schema `struct("x": i64)`.

The structurally identical test 9 (different source/field names) passes.

### 2.2 Root Cause

A race condition between async wiring and data delivery in the test harness.
The following sequence is not guaranteed by Erlang message ordering:

```
1. gen_server:call(Circuit, {circuit_update, ...})   -- sends {wiring_update, ...} via !
2. Input node receives {wiring_update, ...}           -- sets downstream_pids
3. Test sends data via send_epoch_deltas(...)          -- sends {delta, ...} via !
4. Input node receives {delta, ...}                    -- forwards to downstream_pids
```

Steps 2 and 3 can arrive in either order because they are sent from different
processes (`circuit_proc` and the test process).  If step 3 arrives first,
`downstream_pids` is still `[]` (initial state, `test_input_node.erl:29`) and
the delta is silently dropped (`test_input_node.erl:76` loops over empty list).

### 2.3 Evidence

- `gdbsp_circuit_proc.erl:301-330` — `wire_all` sends all wiring updates via
  `!` (async, fire-and-forget).  No synchronization or acknowledgment.

- `gdbsp_test_input_node.erl:29` — initial state has `downstream_pids => []`.
  Data forwarded to empty list is silently dropped (line 76).

- `gdbsp_e2e_SUITE.erl:238-241` — `gen_server:call(Circuit, {circuit_update, ...})`
  returns as soon as `wire_all` finishes sending `!` messages (not after
  receivers have processed them).  `run_epochs` sends data immediately after.

- Erlang does not guarantee ordering between messages from different senders.

### 2.4 Why gordeev-grasp Does Not Hit This

gordeev-grasp's pipeline deployment (`gg_pm_pipeline_proc:handle_call({deploy, ...})`)
returns before any data is sent.  Data delivery happens in a separate
lifecycle stage (`start_epochs` / `send_event`), leaving ample time for
wiring to settle.  The gdbsp e2e test compresses both stages into one
synchronous flow.

The async `!` wiring protocol is identical in both codebases — the
difference is purely in how the test harness sequences deploy and run.

### 2.5 Why Identical Tests Differ

Test 8 (timeout) and Test 9 (passes) have the same circuit structure
(`delay + plus`) but differ in source names and field names.  These
affect the iteration order of `SourceMap` in `send_epoch_done`, which
influences the relative timing of wiring vs. data messages.  The race
is timing-dependent.

### 2.6 Proposed Fix

After `gen_server:call(Circuit, {circuit_update, ...})`, call
`sys:get_state(InputPid)` on each input node.  This synchronous call
forces the gen_server message queue to drain, guaranteeing that
`{wiring_update, ...}` has been processed before data is sent.

**File**: `test/gdbsp_e2e_SUITE.erl`
**Location**: `run_positive/5`, between `circuit_update` and `run_epochs`.

```erlang
ok = gen_server:call(Circuit, {circuit_update, Plan, Inputs, Outputs}),
%% Ensure input nodes have processed their wiring_update messages
%% before sending epoch data.  Without this, data can arrive before
%% downstream_pids is populated (async ! for wiring vs. async ! for
%% data), causing deltas/barriers to be silently dropped.
maps:foreach(fun(_N, {Pid, _T}) -> sys:get_state(Pid) end, SourceMap),
```

This approach is deterministic (no arbitrary sleep duration) and does not
alter the wiring protocol (which is correct for production use).

---

## 3. e2e_fixpoint_selfref — Weight 2 via Dual Data Path

### 3.1 Symptom

The self-ref fixpoint test

```
circuit simple(base: input, result: r):
    result := distinct(r)

src :: stream(struct("v": i64))
fp := fixpoint simple(base: src, result: src)
out := fp.result
```

with input `[{+1, {v: 42}}]` produces the tuple `{v: 42}` with weight 2
instead of 1.  The trivial fixpoint test (`e2e_fixpoint.yaml`, no self-ref)
produces weight 1 correctly.

### 3.2 Root Cause

The output pass-through node `out := plus(fp_result)` is compiled **before**
the fixpoint node `fp` in the topological order, so `fp_result` resolves to
the body distinct node ID at compilation time.  After `build_fixpoint_graph`
returns ExtraIds (`fp_result → RecOutputId`), the `maps:merge` correctly
overrides the IdMap for future name lookups, but the plus node's `inputs`
field was already set to the body distinct node ID and is never updated.

After incrementalization's `wrap_nonlinear` replaces all occurrences of
`distinctId` with `differentiateId` (a standard transformation for non-linear
operators inside fixpoint bodies), the plus node's input becomes the
differentiate node.  This creates **two data paths** to the collector:

| Path | Data flow | Carries |
|------|-----------|---------|
| A | Rec → body → Differentiate → plus node → output_wrapper → collector | Iteration deltas at each round |
| B | Rec → ConsumerDiff → collector | One delta at `epoch_done` |

Both paths carry `{+1, {v: 42}}`.  The collector consolidates them to weight 2.

### 3.3 Evidence

Collector logs confirm two distinct sender PIDs delivering the same data:

```
collector: barrier={iter,0,0} from=<0.650.0> deltas=[{1, {v:42}}]
collector: barrier=undefined from=<0.653.0> deltas=[{1, {v:42}}]
collector: barrier=epoch_done from=<0.653.0> deltas=[]
```

- `<0.650.0>`: the body Differentiate, sending iteration barriers directly
  to the collector through the rogue plus-node path.
- `<0.653.0>`: the Rec process, sending `ConsumerDiff` (data then barrier)
  via the correct `consumers` list.

### 3.4 Why the merge Is Already Correct

In OTP 27, `maps:merge(A, B)` gives priority to B (second argument).
The compile_graph code at `gdbsp_compile_graph.erl:143`:

```erlang
{Merged, _} = maps:merge(IdMapAcc#{Name => NodeId}, ExtraIds)
```

correctly gives priority to ExtraIds (M2).  However, the IdMap fix only
affects subsequent `resolve_input_ids` lookups — it does not retroactively
fix the already-compiled plus node's `inputs` field.

### 3.5 Proposed Fix

After creating RecOutput nodes in `build_fixpoint_graph` and before
returning, scan the graph for any nodes whose inputs contain body node
IDs that are being overridden by RecOutputs, and replace them.  This is
analogous to the `maps:map` substitution in `wrap_nonlinear`
(`gdbsp_compile_incremental.erl` lines 206-217).

**File**: `src/gdbsp_compile_graph.erl`
**Location**: `build_fixpoint_graph/8`, just before the return statement.

```erlang
%% Fix up any nodes whose inputs still reference raw body operator IDs
%% instead of their RecOutput wrappers.  This can happen when the output
%% pass-through node (e.g. "out := plus(fp_result)") is compiled before
%% the fixpoint node in the topological order — its inputs were resolved
%% before build_fixpoint_graph had a chance to install RecOutput overrides
%% in IdMap.
BodyToRecOutput = maps:fold(
    fun(KwBin, RecOutId, Acc) ->
        case maps:find(KwBin, BodyOpIds) of
            {ok, BodyId} -> Acc#{BodyId => RecOutId};
            error -> Acc
        end
    end, #{}, RecOutputIds),
NodesFixed = maps:map(
    fun(_NId, CNode = #circuit_node{inputs = CIns}) ->
        NewIns = lists:map(
            fun(InId) ->
                case maps:find(InId, BodyToRecOutput) of
                    {ok, RecOutId} -> RecOutId;
                    error -> InId
                end
            end, CIns),
        case NewIns =:= CIns of
            true -> CNode;
            false -> CNode#circuit_node{inputs = NewIns}
        end
    end, G6#circuit_graph.nodes),
G7 = G6#circuit_graph{nodes = NodesFixed},
```

After this fix, the plus node's input is corrected to `RecOutputId`,
eliminating the rogue data path.  The output node receives only
`ConsumerDiff` (weight 1).

### 3.6 Side Effects

The following test expectations must be updated from weight 2 to weight 1
(the weight-2 values were added as a workaround during test development):

- `e2e_fixpoint_multi_epoch.yaml`
- `e2e_fixpoint_multi_iter.yaml`

---

## 4. Verification Plan

1. Apply fix #1 (`sys:get_state` sync) and run `e2e_operators_8` — must pass.
2. Apply fix #2 (graph input substitution) and run all self-ref fixpoint tests —
   must pass with weight 1.
3. Run full test suite (`rebar3 ct`) — no regressions beyond the pre-existing
   `mini_test.erl` compilation error.
