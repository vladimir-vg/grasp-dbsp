# Grasp DBSP — Runtime Model

Date: 2026-07-29
Status: draft

---

## 1. Z-set Model

A Z-set is the fundamental data structure in DBSP. It is a multiset
mapping data items to integer weights:

```
Z-set = #{Row => Weight}
```

where weight is a signed integer. Positive weights represent insertions;
negative weights represent deletions (retractions). A Z-set with all
positive weights is a standard multiset; with mixed signs, it represents
a change from one state to another.

### 1.1 Deltas

Streams carry **deltas** — batches of weighted rows:

```
delta = [(Weight, Row)]
```

- `Weight = +1` → insert this row
- `Weight = -1` → retract (delete) this row
- `Weight = 0` → no effect (effectively absent from the stream)

Deltas are the currency of communication between operators. Every operator
receives deltas and produces deltas.

### 1.2 Delta Operations

**Merge (plus):** Combining two streams with the same row sums their weights:

```
merge([(+1, r), (+2, r)]) = [(+3, r)]
```

If weights sum to zero, the row is removed from the Z-set.

**Distinct:** Collapses opposite-weight pairs within a single batch,
preventing redundant computation downstream:

```
distinct([(+1, r), (-1, r)]) = []
distinct([(+1, r), (+1, r)]) = [(+1, r)]
```

### 1.3 Internal Representation

Internally, each record carries metadata alongside the row and weight:

```
record = [Row, Weight, Metadata]
```

The metadata map carries epoch watermarks, barrier tags, timing
information, and routing data. Metadata flows through the circuit
alongside row data and is merged when streams combine.

---

## 2. Epochs

An epoch is the logical time unit within a DBSP circuit. Each epoch
represents one atomic slice of input data, bounded by `epoch_done`
barriers.

### 2.1 Epoch Lifecycle

1. Input data arrives as a batch of deltas for the current epoch
2. After all input is delivered, an `epoch_done` barrier is injected
3. Operators propagate the barrier through the circuit
4. When the barrier reaches output nodes, the epoch's output is emitted
5. The circuit advances to the next epoch

### 2.2 Per-Epoch Processing

Each operator processes one epoch at a time. Within an epoch:

- Deltas flow through the circuit from sources to outputs
- Stateful operators (integrate, join, distinct, aggregate) update their internal Z-sets
- Stateless operators (map, filter, plus, neg, delay, project) transform deltas in-flight
- When `epoch_done` arrives, stateful operators commit their accumulated output

### 2.3 Epoch Batching

Input is delivered in epoch batches. Each batch produces one output batch:

```
Epoch 0 input  →  circuit processing  →  Epoch 0 output
Epoch 1 input  →  circuit processing  →  Epoch 1 output
Epoch 2 input  →  circuit processing  →  Epoch 2 output
```

There is no inter-epoch concurrency within a single circuit — each epoch
completes before the next begins.

---

## 3. Barriers

Barriers are special tags carried in the metadata of delta records.
They are universal synchronization primitives that gate operator output.

### 3.1 Barrier Tags

| Tag | Meaning |
|-----|---------|
| `epoch_done` | End of epoch — operators flush accumulated output and advance to the next epoch |

### 3.2 Barrier Propagation

Barriers propagate through the circuit graph:
- An operator forwards a barrier to its downstream operators after all
  upstream inputs for the current epoch have been received
- A `plus` operator with multiple inputs waits for the barrier from ALL
  inputs before forwarding

### 3.3 Barrier Commit

When an operator receives `epoch_done`:
- Stateful operators (integrate, join, distinct, aggregate) emit all
  accumulated output deltas
- Stateless operators forward the barrier without additional output
- All operators advance their internal epoch counter

---

## 4. Delay Semantics

`delay` is a one-step delay operator: `delay(X)` emits the input from
the **previous** epoch.

### 4.1 Behavior

| Epoch | Input to delay | Output from delay |
|-------|---------------|-------------------|
| 0 | `[(+1, r1)]` | `[]` (no previous epoch) |
| 1 | `[(+1, r2)]` | `[(+1, r1)]` (delayed from epoch 0) |
| 2 | `[(-1, r1)]` | `[(+1, r2)]` (delayed from epoch 1) |

### 4.2 Feedback Loops

`delay` is essential for breaking cycles in feedback loops. A feedback
edge must always pass through a `delay` to ensure the circuit is causal
and well-defined:

```
output_of_cycle := delay(input_to_cycle)
```

Without `delay`, a cycle would produce an infinite loop within a single
epoch.

---

## 5. Operator State

### 5.1 Stateful Operators

Stateful operators maintain internal Z-sets that persist across deltas
and epochs:

| Operator | State |
|----------|-------|
| `integrate` | Accumulated Z-set of all deltas seen so far |
| `join` | Indexed Z-sets for left and right inputs |
| `distinct` | Z-set of previously emitted rows (for deduplication) |
| `aggregate` | Per-group accumulated values (for fold operations) |
| `order` | Full input multiset + previous ranked output (for rank/row-number diffs) |

State is per-operator, per-circuit. There is no shared state between
operators — only deltas flow between them.

### 5.2 Stateless Operators

Stateless operators do not maintain internal state. They transform deltas
in-flight:

- `map` — apply function to each row
- `filter` — pass rows matching predicate
- `flat_map` — expand each row to 0..N rows
- `plus` — merge streams by summing weights
- `neg` — invert weight sign (`+1` ↔ `-1`)
- `delay` — buffer previous epoch's input (one epoch of state, trivially)
- `project` — keep only listed fields

---

## 6. Full vs Delta Mode

Operators can operate in two modes, distinguished by what they receive
as input and produce as output.

### 6.1 Delta Mode

In delta mode, inputs and outputs are **batches of changes** (deltas).
Linear operators naturally operate in delta mode — given input deltas,
they produce output deltas.

### 6.2 Full Mode

In full mode, inputs are the **complete accumulated Z-set** (all rows,
not just changes). Outputs are also complete Z-sets. Non-linear operators
(join, distinct, aggregate, antijoin) require full-mode inputs because
their semantics depend on the complete dataset, not just the changes.

### 6.3 Mode Conversion

`integrate` and `differentiate` convert between modes:

```
integrate:    delta → full    (accumulate)
differentiate: full → delta   (compute change)
```

### 6.4 Incrementalization

The compiler inserts `integrate` / `differentiate` pairs to ensure each
operator receives the correct mode. See [compilation.md](compilation.md) §5
for the incrementalization algorithm.

---

## 7. Input and Output

### 7.1 Input Format

Input to a circuit is provided as epoch batches of deltas. Each record
has the format:

```
[Weight, {field1: Value1, field2: Value2, ...}]
```

where `Weight` is `+1` for insert, `-1` for retract. Values are JSON-encoded
according to the encoding rules in [stdlib.md](stdlib.md) §2.

Example:

```json
[[1, {"id": 1, "val": "100"}],
 [-1, {"id": 1, "val": "100"}]]
```

### 7.2 Output Format

Output from a circuit has the same format as input — epoch batches of
weighted rows. The runtime selects which nodes serve as outputs externally.
The same `.gdbsp` source can be used with different output selections.

The concrete JSONL serialization (one line per delta) and the runtime-owned
epoch ingress (a unit-batch coordinator that segments input rows into epochs)
are specified in [cli.md](cli.md) §5 and §6.

---

## 8. Execution Model

A DBSP circuit is executed by the runtime as a network of communicating
processes:

1. Source nodes receive input deltas from external input processes
2. Each operator processes deltas as they arrive
3. Deltas flow through the circuit graph according to the wiring plan
4. Output nodes emit deltas to external collectors or subscribers
5. Barriers synchronize the circuit at epoch boundaries

The circuit graph is acyclic in the forward direction (except for feedback
edges through `delay`, which break cycles at epoch boundaries). This ensures
that each epoch processes to completion in bounded time.
