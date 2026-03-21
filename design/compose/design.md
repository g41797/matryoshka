# odin-itc — Normative Specification

> **This is the single source of truth.**
> All API signatures, contracts, and invariants are defined here.
> When this file contradicts any other document — this file wins.

Cross-reference: [Golden Contract](../sync/golden-contract.md) — read it first if you haven't.

---

## Decision Log

Contradictions found in the four source documents and resolved here:

| # | Issue | Resolution |
|---|-------|------------|
| 1 | `mbox_send` / `mbox_wait_receive` return values ignored in all examples | All examples now check return value. API returns `SendResult` / `RecvResult` enum — ignoring it is a bug. |
| 2 | `policy.dispose` (field name) vs `flow_dispose` (user proc name) — two names for the same thing | `FlowPolicy.dispose` = struct field (stays). `flow_dispose` = canonical name for the user's implementation. Call sites use `flow_dispose(ctx, alloc, &m)`. Pool calls it internally as `policy.dispose(...)`. Both explained once here. |
| 3 | "defer pool_put is unconditionally safe" — false if id is invalid | Qualified: safe for valid ids. Panics on unknown id — this is a programming error, not a recoverable condition. Panic surfaces it immediately. |
| 4 | Double-put in receiver: `defer pool_put` at top + `pool_put` per case | Kept as intentional safety-net pattern. Cases set `m^ = nil` via explicit `pool_put` — defer becomes no-op. If a case panics or exits early, defer fires and recycles. Explained below. |
| 5 | `mbox_close` had no return value in one doc | Fixed: `mbox_close :: proc(mb: ^Mailbox) -> ^PolyNode`. Returns remaining node chain. |
| 6 | `FlowId` values started at 0 in some examples | All ids must be > 0. Zero is reserved/invalid. Examples now use `Chunk = 1, Progress = 2`. |
| 7 | API naming was mixed (dot notation vs underscore) | Underscore everywhere: `pool_init`, `pool_get`, `mbox_send`, etc. |

---

## 1. Core Type

```odin
import list "core:container/intrusive/list"

PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int,       // type discriminator, stamped by factory, must be > 0
}
```

Reminder — `list.Node`:
```odin
Node :: struct {
    prev, next: ^Node,
}
```

Every type that travels through itc embeds `PolyNode` at **offset 0** via `using`:

```odin
Chunk :: struct {
    using poly: PolyNode,   // offset 0 — required
    data: [CHUNK_SIZE]byte,
    len:  int,
}

Progress :: struct {
    using poly: PolyNode,   // offset 0 — required
    percent: int,
}
```

`using` promotes fields upward: `chunk.id == chunk.poly.id`, `chunk.next == chunk.poly.next`.

**Offset 0 rule** — enforced by convention. The cast `(^Chunk)(node)` is valid only if `PolyNode` is first. itc has no compile-time check for this.

---

## 2. Ownership Contract

All itc APIs pass items through `^Maybe(^PolyNode)`.

```odin
m: Maybe(^PolyNode)

// m^ != nil  →  you own it. You must transfer, recycle, or dispose it.
// m^ == nil  →  not yours. Transfer complete, or nothing here.
// m == nil   →  nil handle. Invalid. API returns error.
```

This replaces separate ownership flags, reference counts, or return-value pointers.

**Entry rules** (what every API checks on input):

| `m` value | Meaning | API response |
|-----------|---------|--------------|
| `m == nil` | nil handle | `.Invalid` |
| `m^ == nil` | caller holds nothing | `.Invalid` (for send) / `.Already_In_Use` (for receive if you pass non-nil `out^`) |
| `m^ != nil` | caller owns item | proceed |

**Exit rules** (what every API guarantees on output):

| Event | `m^` after return |
|-------|------------------|
| success (send, put) | `nil` — ownership transferred |
| success (get, receive) | `non-nil` — you own it now |
| failure (send closed/full) | unchanged — you still own it |
| `pool_put` always | `nil` — or panic on unknown id |

→ Full table in [Golden Contract](../sync/golden-contract.md).

---

## 3. Mailbox API

Mailbox moves items between threads. It is type-erased — operates on `^PolyNode` only.

### Types

```odin
Mailbox :: struct {
    head:   ^PolyNode,
    tail:   ^PolyNode,
    closed: bool,
}

SendResult :: enum {
    Ok,
    Closed,
    Full,
    Invalid,
    Already_In_Use,
}

RecvResult :: enum {
    Ok,
    Empty,
    Closed,
    Already_In_Use,
}
```

### Init / Destroy

```odin
mbox_init    :: proc(mb: ^Mailbox)
mbox_destroy :: proc(mb: ^Mailbox)
```

### send — blocking, ownership transfer

```odin
mbox_send :: proc(mb: ^Mailbox, m: ^Maybe(^PolyNode)) -> SendResult
```

| Entry | Contract |
|-------|----------|
| `m == nil` | returns `.Invalid` |
| `m^ == nil` | returns `.Invalid` |
| `m^ != nil` | proceed |

| Result | `m^` after return |
|--------|------------------|
| `.Ok` | `nil` — enqueued, ownership transferred |
| `.Closed`, `.Full`, others | unchanged — caller still owns |

**Always check the return value.** On non-Ok, the item is still yours — dispose or retry.

### push — non-blocking send

```odin
mbox_push :: proc(mb: ^Mailbox, m: ^Maybe(^PolyNode)) -> SendResult
```

Same contract as `mbox_send`. Must not block.

### wait_receive — blocking receive

```odin
mbox_wait_receive :: proc(mb: ^Mailbox, out: ^Maybe(^PolyNode)) -> RecvResult
```

| Entry | Contract |
|-------|----------|
| `out == nil` | returns `.Invalid` |
| `out^ != nil` | returns `.Already_In_Use` — caller holds an item, refusing to overwrite |
| `out^ == nil` | proceed |

| Result | `out^` after return |
|--------|---------------------|
| `.Ok` | non-nil — dequeued, ownership transferred to caller |
| `.Closed`, `.Empty`, others | unchanged — caller owns nothing |

**Always check the return value.** On non-Ok, `out^` is unchanged (nil) — do not proceed.

### try_receive — non-blocking receive

```odin
mbox_try_receive :: proc(mb: ^Mailbox, out: ^Maybe(^PolyNode)) -> RecvResult
```

Same contract as `mbox_wait_receive`. Returns `.Empty` if queue is empty.

### try_receive_batch — non-blocking, returns chain

```odin
mbox_try_receive_batch :: proc(
    mb:    ^Mailbox,
    out:   ^Maybe(^PolyNode), // becomes head of linked chain
    count: ^int,
) -> RecvResult
```

- Returns a linked chain of all currently queued nodes.
- `out^` becomes the first node. Caller owns the entire chain.
- Walk chain via `node.next` until nil. Call `pool_put` or `flow_dispose` on each.

### close

```odin
mbox_close :: proc(mb: ^Mailbox) -> ^PolyNode
```

- After close: further `mbox_send` returns `.Closed`.
- Returns head of remaining node chain (nil if empty).
- **Caller must drain the chain.** Walk via `node.next`, call `flow_dispose` on each node.

---

## 4. Pool API

Pool holds reusable items. Type-erased — operates on `^PolyNode` only.
Pool is mechanism only. All lifecycle decisions (allocation, backpressure, disposal) live in `FlowPolicy`.

### Types

```odin
Pool :: struct {
    // Internal — MPMC free-lists, per-id accounting.
    // Access only through API.
}

Pool_Get_Mode :: enum {
    Recycle_Or_Alloc, // check free-list first; call factory if empty
    Alloc_Only,       // always call factory; ignore free-list
    Recycle_Only,     // free-list only; return false if empty — never allocates
}
```

### FlowPolicy

```odin
FlowPolicy :: struct {
    ctx: rawptr, // user context — carries allocator, master, or any state

    // Called when factory is needed (Recycle_Or_Alloc miss or Alloc_Only).
    // in_pool_count: items of this id currently in the free-list.
    // Allocates correct concrete type, stamps node.id, returns ^PolyNode.
    factory: proc(ctx: rawptr, alloc: mem.Allocator, id: int, in_pool_count: int) -> (^PolyNode, bool),

    // Called BEFORE pool_get returns a recycled item to caller.
    // Use for zeroing or sanitizing stale data. Must NOT free internal resources.
    on_get:  proc(ctx: rawptr, m: ^Maybe(^PolyNode)),

    // Called during pool_put, outside lock.
    // m^ == nil after hook → pool discards (consumed, e.g. backpressure).
    // m^ != nil after hook → pool MUST add to free-list. This is an invariant, not optional.
    on_put:  proc(ctx: rawptr, alloc: mem.Allocator, in_pool_count: int, m: ^Maybe(^PolyNode)),

    // Called for every node remaining in the pool during pool_destroy.
    // Frees all internal resources and the node itself. Sets m^ = nil.
    // User implementation is conventionally named `flow_dispose`.
    dispose: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode)),
}
```

**`ctx` is runtime** — cannot be set in a `::` compile-time constant. Set it before calling `pool_init`.

All four proc fields are optional. `nil` = default behavior (factory required for allocation to work).

### dispose hook naming

`FlowPolicy.dispose` is the field name. The user writes the implementation and conventionally names it `flow_dispose`:

```odin
// User implementation — any name works, flow_dispose is conventional
flow_dispose :: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode)) { ... }

// Registered in FlowPolicy
FLOW_POLICY :: FlowPolicy{
    ...
    dispose = flow_dispose,
}
```

When you need to manually dispose an item (drain, shutdown, byte-limit exceeded):
```odin
flow_dispose(ctx, alloc, &m)    // call your proc directly
```

The pool calls it internally during `pool_destroy` as `policy.dispose(ctx, alloc, &m)`.

**Bottom line**: `FlowPolicy.dispose` is the field. `flow_dispose` is what you call from user code. They point to the same proc.

### Init / Destroy

```odin
pool_init    :: proc(p: ^Pool, policy: FlowPolicy, ids: []int, alloc := context.allocator)
pool_destroy :: proc(p: ^Pool)
```

`ids`: complete set of valid item ids for this pool. All must be > 0. Non-empty.

`pool_destroy` behavior:
1. Drains all free-lists.
2. Calls `policy.dispose` on every drained node.
3. Frees internal accounting.

### get — acquire ownership

```odin
pool_get :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, out: ^Maybe(^PolyNode)) -> (ok: bool)
```

| Mode | Behavior |
|------|----------|
| `.Recycle_Or_Alloc` | check free-list; call `on_get` on hit; call `factory` on miss |
| `.Alloc_Only` | always call `factory`; skip free-list |
| `.Recycle_Only` | free-list only; return `false` if empty |

Returns `true` on success, `out^` set to item. Returns `false` on failure, `out^` unchanged.

### put — return to pool

```odin
pool_put :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Exact algorithm — in this order:

1. Check `m.?.id` against the pool's registered id set → **PANIC if not found** (programming error)
2. Get `in_pool_count` for this id (under lock, then unlock)
3. Call `policy.on_put(ctx, alloc, in_pool_count, m)` — **outside lock**
4. If `m^` is still non-nil → push to free-list, increment count, set `m^ = nil` (under lock)

**After `pool_put` returns, `m^` is always nil.** Either recycled (step 4) or consumed by `on_put` (step 3). The panic in step 1 means no silent "what happens on unknown id" — it crashes immediately.

### defer pool_put — when is it safe?

```odin
m: Maybe(^PolyNode)
if pool_get(&p, id, .Recycle_Or_Alloc, &m) {
    defer pool_put(&p, &m)  // safety net
    // ... work ...
}
```

Three outcomes when `defer pool_put` fires:
- `m^ == nil` (item was transferred via `mbox_send`) → `pool_put` is a no-op
- `m^ != nil` (item was not transferred) → `pool_put` recycles or `on_put` disposes
- `m^ != nil` with unknown id → `pool_put` panics — programming error, surfaces immediately

**Safe for valid ids. Panics on unknown id.** The panic is the correct behavior — it tells you exactly where the bug is.

### put_all — return a chain

```odin
pool_put_all :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Walks the linked list from `m^`, calls `pool_put` on each node. Used after `mbox_try_receive_batch`.

---

## 5. ID System

### Rules

- Every item id must be > 0 (zero is reserved/invalid)
- `pool_init` accepts the complete set of valid ids for this pool
- `pool_put` checks the item's id on every call — **unknown id causes immediate panic**
- `factory` stamps `node.id` at allocation time
- Id values are user-defined integer constants — typically from an enum

### Why panic on unknown id?

A foreign id on `pool_put` is almost always a bug: wrong cast earlier, wrong pool, memory corruption, or use-after-free. Silent recycling would create silent starvation or use-after-free later. A loud panic during development is far cheaper than hunting ghosts in production.

### Example

```odin
FlowId :: enum int {
    Chunk    = 1,  // must be > 0
    Progress = 2,
}

// Registration at pool_init
pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, alloc)
```

---

## 6. FlowPolicy Hooks — Reference

All hooks are called **outside the pool mutex**. This is guaranteed. Hooks may safely access `ctx` which may contain application-level locks, without deadlock risk.

### factory

```odin
factory :: proc(ctx: rawptr, alloc: mem.Allocator, id: int, in_pool_count: int) -> (^PolyNode, bool)
```

Called when a new allocation is needed (`Recycle_Or_Alloc` miss or `Alloc_Only`).
Must allocate the correct concrete type for `id`, stamp `node.id = id`, return `^PolyNode`.

```odin
flow_factory :: proc(ctx: rawptr, alloc: mem.Allocator, id: int, in_pool_count: int) -> (^PolyNode, bool) {
    #partial switch FlowId(id) {
    case .Chunk:
        c := new(Chunk, alloc)
        if c == nil { return nil, false }
        c.id = id
        return (^PolyNode)(c), true
    case .Progress:
        p := new(Progress, alloc)
        if p == nil { return nil, false }
        p.id = id
        return (^PolyNode)(p), true
    }
    return nil, false
}
```

### on_get

```odin
on_get :: proc(ctx: rawptr, m: ^Maybe(^PolyNode))
```

Called before `pool_get` returns a **recycled** item to caller. Not called for freshly allocated items.
Use for zeroing or sanitizing stale data. **Must NOT free internal resources.**

```odin
flow_on_get :: proc(ctx: rawptr, m: ^Maybe(^PolyNode)) {
    if m == nil || m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:    (^Chunk)(node).len = 0
    case .Progress: (^Progress)(node).percent = 0
    }
}
```

### on_put

```odin
on_put :: proc(ctx: rawptr, alloc: mem.Allocator, in_pool_count: int, m: ^Maybe(^PolyNode))
```

Called during `pool_put`, outside lock.

- `in_pool_count`: current count of items with this id in the free-list. Use it to decide backpressure.
- If hook sets `m^ = nil` → item is consumed (e.g. disposed to shed load). Pool will not add it to free-list.
- If hook leaves `m^ != nil` → pool **must** add to free-list. This is an invariant.

```odin
flow_on_put :: proc(ctx: rawptr, alloc: mem.Allocator, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    if m == nil || m^ == nil { return }
    #partial switch FlowId(m.?.id) {
    case .Chunk:
        if in_pool_count > 400 {
            flow_dispose(ctx, alloc, m)  // consume to enforce limit
        }
    case .Progress:
        if in_pool_count > 128 {
            flow_dispose(ctx, alloc, m)  // consume to enforce limit
        }
    }
    // m^ still non-nil here → pool will add to free-list
}
```

### dispose (flow_dispose)

```odin
dispose :: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode))
```

Called during `pool_destroy` for every node remaining in the pool.
Also called directly from user code for permanent disposal (drain, shutdown, byte-limit exceeded).

Must:
- Route by `node.id`
- Free internal resources per type
- Free the node struct itself
- Set `m^ = nil`
- Be safe on partially-initialized structs

```odin
flow_dispose :: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode)) {
    if m == nil  { return }
    if m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:
        free((^Chunk)(node), alloc)
    case .Progress:
        free((^Progress)(node), alloc)
    }
    m^ = nil
}
```

Call from user code:
```odin
flow_dispose(policy.ctx, alloc, &m)    // permanent disposal — not recycled
```

---

## 7. Full Lifecycle Example

Sender and receiver are in separate threads. `m` variables are different.

### Setup

```odin
FlowId :: enum int { Chunk = 1, Progress = 2 }

FLOW_POLICY :: FlowPolicy{
    factory = flow_factory,
    on_get  = flow_on_get,
    on_put  = flow_on_put,
    dispose = flow_dispose,
}

// init — ctx is runtime, set before pool_init
policy := FLOW_POLICY
policy.ctx = &master

pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, master.allocator)
mbox_init(&mb)
```

### Sender

```odin
m: Maybe(^PolyNode)

if !pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) {
    return  // pool empty or factory failed
}
defer pool_put(&p, &m)  // safety net: fires if send fails

// fill
c := (^Chunk)(m.?)
c.len = fill(c.data[:])

// transfer
if mbox_send(&mb, &m) != .Ok {
    return  // send failed — m^ unchanged, defer pool_put recycles
}
// m^ is nil — transfer done — defer pool_put is a no-op
```

### Receiver

```odin
m: Maybe(^PolyNode)

if mbox_wait_receive(&mb, &m) != .Ok {
    return  // mailbox closed — m^ is unchanged (nil)
}
defer pool_put(&p, &m)  // safety net — fires if switch case exits early

switch FlowId(m.?.id) {
case .Chunk:
    c := (^Chunk)(m.?)
    process_chunk(c)
    pool_put(&p, &m)    // explicit return — m^ = nil — defer is no-op

case .Progress:
    pr := (^Progress)(m.?)
    update_progress(pr)
    pool_put(&p, &m)    // explicit return — m^ = nil — defer is no-op

// no case exits without returning the item
}
```

**Why both `defer pool_put` and per-case `pool_put`?**

The per-case `pool_put` is the normal path — it sets `m^ = nil`. After that, the deferred `pool_put` fires and sees `m^ == nil`, so it is a no-op. The `defer` is a safety net for paths you did not anticipate (added cases, early returns, panics in process procs). This is belt and suspenders — intentional.

### Shutdown

```odin
// Sender side — close mailbox
head := mbox_close(&mb)

// drain remaining items
node := head
for node != nil {
    next := node.next
    m: Maybe(^PolyNode) = node
    flow_dispose(policy.ctx, alloc, &m)  // permanent disposal
    node = next
}

// destroy pool — calls policy.dispose on all items in free-list
pool_destroy(&p)
```

---

## 8. Pre-allocating (Seeding the Pool)

To avoid runtime latency, pre-allocate before starting threads:

```odin
pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, alloc)

for _ in 0..<100 {
    m: Maybe(^PolyNode)
    if pool_get(&p, int(FlowId.Chunk), .Alloc_Only, &m) {
        pool_put(&p, &m)  // put back immediately — goes to free-list
    }
}
```

`Alloc_Only` skips the free-list and always calls `factory`. Here we use it to force 100 fresh allocations into the pool.

---

## 9. Pool Get Modes

Mode is a per-call parameter of `pool_get`. Not a pool-wide setting.

```odin
// Normal operation — recycle if available, allocate if not
pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m)

// Force allocation — use for seeding or when you want a guaranteed fresh item
pool_get(&p, int(FlowId.Chunk), .Alloc_Only, &m)

// Recycle only — use in no-alloc paths (e.g. interrupt handlers)
// Returns false if free-list is empty — never allocates
ok := pool_get(&p, int(FlowId.Chunk), .Recycle_Only, &m)
if !ok {
    // free-list was empty — handle: skip, back off, or signal producer
}
```

---

## 10. Invariants

| # | Invariant | Consequence of violation |
|---|-----------|--------------------------|
| I1 | `m^` is the ownership bit. Non-nil = you own it. | Double-free or leak. |
| I2 | All hooks called outside pool mutex. | Guaranteed by pool. User may hold their own locks inside hooks. |
| I3 | `on_get` is called on every recycled item before it reaches caller. | No stale data leaks into new lifecycle. |
| I4 | Pool maintains per-id `in_pool_count`. Passed to `factory` and `on_put`. | Enables accurate backpressure. |
| I5 | Unknown id on `pool_put` → immediate panic. | Programming errors surface immediately, not silently. |
| I6 | `on_put`: if `m^ != nil` after hook → pool MUST add to free-list. | Invariant. If hook wants to discard, it must set `m^ = nil`. |

---

## 11. What itc owns vs what you own

### itc owns

- `PolyNode` shape — `node` + `id`
- `^Maybe(^PolyNode)` ownership contract across all APIs
- Pool modes per `pool_get` call
- Hook dispatch — `factory` / `on_get` / `on_put` / `dispose` called with `ctx`
- Guarantee: hooks called outside pool mutex
- `pool_put` — always sets `m^ = nil` after return (or panics on unknown id)
- `mbox_close` — returns remaining chain, caller must drain

### You own

- Id enum definition (`FlowId`)
- All `FlowPolicy` hook implementations
- Locking inside hooks — pool makes no constraints on hook internals
- Per-id count limits — expressed in `on_put`
- Byte-level limits — maintain a counter in `ctx`, call `flow_dispose` when over limit
- Receiver switch logic and casts
- Returning every item to pool — via `pool_put`, `flow_dispose`, or `mbox_send`
