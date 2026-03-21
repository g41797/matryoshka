```markdown
# The Golden Contract
**^Maybe(^PolyNode) + Strict ID Panic**

This is the **single most important rule** of odin-itc.
Everything else — pool modes, mailbox mechanics, FlowPolicy hooks, backpressure — is built around it or exists to serve it.

## Core Invariant

**Ownership exists if and only if** `m^ != nil`

```odin
import list "core:container/intrusive/list"

PolyNode :: struct {
    using node: list.Node,   // .prev, .next
    id:         int,         // your type tag
}
```

Reminder:
```odin
// The list link you must include in your own structure.
Node :: struct {
	prev, next: ^Node,
}
```


```odin
m: Maybe(^PolyNode)

// You own it           →  m^ != nil
// You do NOT own it    →  m^ == nil
```

There is **exactly one way** to know whether you are responsible for an item:
look at the inner pointer of the `Maybe`.

- `m^ != nil` → **you own** the item — you **must** eventually transfer it, return it to the pool, or dispose of it
- `m^ == nil` → **transferred / consumed / gone** — do **not** touch the pointer anymore
- `m == nil`  → **out of lack**

It replaces enums, return codes, reference counts, and ownership flags, at least tries...

## Uniform Transfer Contract

Every ownership-moving API in odin-itc obeys **exactly the same entry/exit rules**:

| API                | On entry (caller responsibility)          | On success (what happens to `m^`) | On most failures                  | Special failure case              |
|--------------------|--------------------------------------------|------------------------------------|-----------------------------------|-----------------------------------|
| `pool_get`         | `m^` must be `nil` (or `.Already_In_Use`) | `m^ = fresh or recycled item`      | `m^` unchanged                    | —                                 |
| `mbox_send`        | caller owns via `m^ != nil`                | `m^ = nil` (transferred)           | `m^` unchanged (Closed,  …)  | —                                 |
| `pool_put`         | caller owns via `m^ != nil`                | `m^ = nil` (always, or panic)      | panic (unknown id)                | —                                 |
| `flow_dispose`     | caller owns via `m^ != nil`                | `m^ = nil` (destroyed)             | —                                 | —                                 |
| `mbox_wait_receive`| `out^` must be `nil`                       | `out^ = dequeued item`             | `out^` unchanged                  | `.Already_In_Use` if `out^ != nil`|

**Key consequences:**

- `defer pool_put(&p, &m)` is **unconditionally safe** (after success or panic)
- One variable can safely travel the entire lifecycle: `get → fill → send → receive → process → put`
- No need to track separate “is owned” flags or copy pointers into temporary variables

## The Other Half: Strict ID Panic

The second pillar of the golden contract is **fail-fast identity validation**.

```text
pool_init(…, ids = {1, 2, 5, 42, …})
```

- Every `pool_put` checks `m.?.id` against the registered set
- **Unknown id → immediate panic**
  (this is considered a **programming error**, not a recoverable condition)

### Why panic instead of silent drop / foreign handling?

- In message-passing systems, foreign/wrong-type items are almost always bugs
  (wrong cast earlier, wrong pool, memory corruption, use-after-free)
- Silent recycling or dropping creates **silent starvation** or **use-after-free** later
- A loud crash during development/testing is far cheaper than hunting ghosts in production

This is the deliberate trade-off:
**developer-time safety > runtime leniency**

## Visual Lifecycle (one variable)

```text
          pool_get(&p, id, mode, &m)
                   ↓                m^ = item (you own)
             fill / use
                   ↓
       mbox_send(&mb, &m)    ── success ──→  m^ = nil (transferred)
             │                                 failure ──→  m^ unchanged (still yours)
             ↓
   mbox_wait_receive(&mb, &m)               m^ = item (now you own again)
                   ↓
             process / switch on id
                   ↓
         pool_put(&p, &m)                   m^ = nil (recycled or on_put disposed)
                   │
             or flow_dispose(…)             m^ = nil (permanently gone)
```

## Golden Rules Summary (copy-paste reminders)

```odin
// [golden] — check before using
if m^ == nil { return .NothingToDo }     // transferred already — do nothing

// [golden] — never copy the pointer
// BAD:  let temp = m^;  send(&mb, &temp)  ← two owners, disaster
// GOOD: send(&mb, &m)                     ← one variable, one owner

// [golden] — defer is your safety net
defer pool_put(&p, &m)                   // always safe (nil → no-op, non-nil → recycle/dispose/panic)
```

## Where to look next

- [Mailbox API](./mailbox.md) — detailed send/receive contracts
- [Pool API](./pool.md) — modes, FlowPolicy hooks, backpressure via `on_put`
- [Idioms](./idioms.md) — `defer-put`, `heap-master`, `thread-container`

This contract is **not optional**.
It is the spine of odin-itc.
Violate it → expect crashes, leaks, or corruption.
Respect it → most ownership bugs become impossible by construction.

**One variable. One bit. One panic on unknown id.**
That’s the golden contract.
