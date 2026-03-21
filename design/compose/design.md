# odin-itc — Normative Specification

> **This is the single source of truth.**
> All API signatures, contracts, and invariants are defined here.
> When this file contradicts any other document — this file wins.

Cross-reference: [Golden Contract](../sync/golden-contract.md) — read it first if you haven't.

---

## What is itc? Why use it?

**itc** is an inter-thread communication library for Odin. It gives you mailboxes — typed message queues where ownership is explicit and transfer is zero-copy.

The mailbox idea goes back to the actor model (1973). The core insight: threads should not share memory — they should pass messages. When a message moves from one thread to another, exactly one thread owns it at any moment. No locks on the message itself. No copies.

**Why not channels?** Odin's built-in channels are fine for many uses. itc helps when they don't fit:

- **Zero allocation on the hot path** — items are recycled through a pool, not re-allocated for every message.
- **Intrusive nodes** — the queue link lives inside your struct, not in a separate heap node. One allocation per item, ever.
- **Interrupt** — unblock a waiting receiver without closing the mailbox. Useful for shutdown signalling that needs to round-trip cleanly.
- **Timeout** — `wait_receive` accepts a duration. Pass `0` for non-blocking poll, `-1` for infinite wait.
- **Controlled shutdown** — `mbox_close` returns all in-flight items as a drainable list. Nothing is leaked.
- **Type-erased transport** — pool and mailbox operate on `^PolyNode` only. The concrete type lives only in your code.

If channels work for you — use them. itc helps when they don't.

---

## Decision Log

Contradictions found in the four source documents and resolved here:

| # | Issue | Resolution |
|---|-------|------------|
| 1 | `mbox_send` / `mbox_wait_receive` return values ignored in all examples | All examples now check return value. API returns `SendResult` / `RecvResult` enum — ignoring it is a bug. |
| 2 | `policy.dispose` (field name) vs `flow_dispose` (user proc name) — two names for the same thing | `FlowPolicy.dispose` = struct field (stays). `flow_dispose` = canonical name for the user's implementation. Call sites use `flow_dispose(ctx, alloc, &m)`. Pool calls it internally as `policy.dispose(...)`. Both explained once here. |
| 3 | "defer pool_put is unconditionally safe" — false if id is invalid | Qualified: safe for valid ids. Panics on unknown id — this is a programming error, not a recoverable condition. Panic surfaces it immediately. |
| 4 | Double-put in receiver: `defer pool_put` at top + `pool_put` per case | Kept as intentional safety-net pattern. Cases set `m^ = nil` via explicit `pool_put` — defer becomes no-op. If a case panics or exits early, defer fires and recycles. Explained below. |
| 5 | `mbox_close` had no return value in one doc, wrong type in another | Fixed: `mbox_close :: proc(mb: ^Mailbox) -> list.List`. Returns remaining items as a `list.List`. Empty list if already closed. |
| 6 | `FlowId` values started at 0 in some examples | All ids must be > 0. Zero is reserved/invalid. Examples now use `Chunk = 1, Progress = 2`. |
| 7 | API naming was mixed (dot notation vs underscore) | Underscore everywhere: `pool_init`, `pool_get`, `mbox_send`, etc. |
| 8 | `SendResult` / `RecvResult` did not match implementation | Updated: `SendResult{Ok,Closed,Invalid}`, `RecvResult{Ok,Closed,Interrupted,Already_In_Use,Invalid,Timeout}`. Old `Mailbox_Error` merged and split across the three result enums. |
| 9 | `mbox_interrupt` was missing from the API | Added. Returns `IntrResult{Ok,Closed,Already_Interrupted}`. |
| 10 | `mbox_wait_receive` had no timeout parameter | Added `timeout: time.Duration = -1`. `-1` = infinite, `0` = non-blocking poll. `Timeout` added to `RecvResult`. |
| 11 | `mbox_try_receive` listed as a separate proc | Dropped. Use `mbox_wait_receive(mb, out, 0)` instead (timeout=0). |
| 12 | Mailbox and Pool struct internals were exposed | Hidden. Both show `...............` — access only through API. |
| 13 | `pool_put` only panicked on unknown id, not on id==0 | Updated: panics on `id==0` (zero always invalid, system-wide) AND on id not in the pool's registered set. |

---

## Core Type

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

### Intrusive

A **non-intrusive** queue allocates a wrapper node around your data:

```
[ queue node ] → [ your struct ]   ← two allocations, two pointer hops
    .next
    .data  ──────────────────────►
```

An **intrusive** queue puts the link inside your struct:

```
[ your struct                 ]   ← one allocation
    PolyNode.node.next ──────────► next item in queue
    PolyNode.id
    your fields...
```

With `using poly: PolyNode` at offset 0, your struct *is* the node. No wrapper. No extra allocation. No extra pointer hop.

`PolyNode` is itc's intrusive node. Pool and Mailbox operate on `^PolyNode` — which is also `^YourStruct` when offset 0 holds. The cast is safe because you placed `PolyNode` first.

**Consequence** — an item lives in exactly one place at a time. It cannot be in two queues simultaneously. Ownership is structural, not tracked by a flag.

### Type Erased

Pool and Mailbox do not know what types they carry. They receive `^PolyNode`, store `^PolyNode`, return `^PolyNode`. They are pipes.

All concrete type knowledge lives in user code — in `factory`, `on_get`, `on_put`, `dispose`, and in the receiver's `switch` statement. `PolyNode.id` is the discriminator that makes the cast safe.

This is the same pattern Odin's stdlib uses throughout: `thread.create` takes `data: rawptr`, `context.user_ptr` is `rawptr`, `mem.Allocator` passes `rawptr`. The type disappears at the boundary and reappears in the implementation.

```odin
// Pool side — type-erased
pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m)  // returns ^PolyNode

// User side — typed
c := (^Chunk)(m.?)   // safe because factory stamped id = FlowId.Chunk and placed PolyNode at offset 0
```

The id is the contract. Zero is always invalid. Unknown id panics. Known id → safe cast.

---

## Participants

itc has five participant roles. Only one of them — **Master** — knows concrete types.

### Items

User-defined structs with `PolyNode` embedded at offset 0 via `using`. Examples: `Chunk`, `Progress`, `Command`.

Items travel through the system as `^PolyNode`. Only the Master that allocated or received them casts back to the concrete type.

```odin
Chunk :: struct {
    using poly: PolyNode,   // offset 0 — required
    data: [CHUNK_SIZE]byte,
    len:  int,
}
```

### Pool

A type-erased recycler. Holds free items as `^PolyNode`. Hands them out via `pool_get`, takes them back via `pool_put`. Knows nothing about what is inside the items.

All lifecycle logic (allocation, reset, backpressure, disposal) is delegated to `FlowPolicy` hooks that live in user code.

### Mailbox

A type-erased transporter. Moves `^PolyNode` from one Master to another across thread boundaries. Blocking, with optional timeout. Supports interrupt and close.

Mailbox knows nothing about item types. It holds ownership during transit and releases it to the receiver on success.

### Master

A user struct that runs on a thread. The only participant that knows concrete types.

Master owns the pools and mailboxes that belong to its domain. It calls `pool_get` to acquire items, fills them, sends via `mbox_send`. On the receive side it calls `mbox_wait_receive`, switches on `id`, casts to the concrete type, processes, and returns via `pool_put`.

Master lives on the heap. It is the unit of work in itc.

```odin
Master :: struct {
    pool:  Pool,
    inbox: Mailbox,
    // ... other mailboxes, state, allocator ...
}
```

### Thread

A thin container that runs exactly one Master. It holds only `^Master`. It declares no itc objects itself — those belong to Master.

```odin
// Thread proc
run :: proc(arg: rawptr) {
    m := (^Master)(arg)
    master_run(m)
}
```

### Typical flow

```
Master A                                   Master B
────────                                   ────────
pool_get(&p, .Chunk, ...)     ──────►
fill chunk                                 mbox_wait_receive(&inbox, &m)
mbox_send(&inbox, &m)         ──────►      switch m.?.id
                                           case .Chunk: (^Chunk)(m.?) → process
                                           pool_put(&p, &m)
```

**Why ownership matters here:** Mailbox and Pool are opaque — they cannot track what type they hold. The Master is the only actor that can safely cast `^PolyNode` back to a concrete type. This is why only one Master should hold a given item at any moment, and why the `^Maybe(^PolyNode)` contract (nil = you don't own it) is enforced at every API boundary.

---

## Ownership Contract

All itc APIs pass items using `^Maybe(^PolyNode)`.

```odin
m: Maybe(^PolyNode)

// m^ != nil  →  you own it. You must transfer, recycle, or dispose it.
// m^ == nil  →  not yours. Transfer complete, or nothing here.
// m == nil   →  nil handle. Invalid. API returns error.
```

This replaces separate ownership flags, reference counts, or return-value pointers.
Not for all, but for most cases.

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
| failure (send closed) | unchanged — you still own it |
| `pool_put` always | `nil` — or panic on unknown id |

→ Full table in [Golden Contract](../sync/golden-contract.md).

---

## Mailbox API

Mailbox moves items between Masters (threads). It is type-erased — operates on `^PolyNode` only.

### Types

```odin
Mailbox :: struct {
    ...............
}

SendResult :: enum {
    Ok,
    Closed,
    Invalid,
}

RecvResult :: enum {
    Ok,
    Closed,
    Interrupted,
    Already_In_Use,
    Invalid,
    Timeout,
}

IntrResult :: enum {
    Ok,
    Closed,
    Already_Interrupted,
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
| `m^.id == 0` | returns `.Invalid` |
| `m^ != nil` | proceed |

| Result | `m^` after return |
|--------|------------------|
| `.Ok` | `nil` — enqueued, ownership transferred |
| `.Closed`, `.Invalid` | unchanged — caller still owns |

**Always check the return value.** On non-Ok, the item is still yours — dispose or retry.

### wait_receive — blocking receive, with timeout

```odin
mbox_wait_receive :: proc(mb: ^Mailbox, out: ^Maybe(^PolyNode), timeout: time.Duration = -1) -> RecvResult
```

`timeout` values:
- `-1` — wait forever (default)
- `0` — non-blocking poll (returns `.Timeout` immediately if empty)
- `> 0` — wait up to this duration, then return `.Timeout`

| Entry | Contract |
|-------|----------|
| `out == nil` | returns `.Invalid` |
| `out^ != nil` | returns `.Already_In_Use` — caller holds an item, refusing to overwrite |
| `out^ == nil` | proceed |

| Result | `out^` after return |
|--------|---------------------|
| `.Ok` | non-nil — dequeued, ownership transferred to caller |
| `.Closed`, `.Interrupted`, `.Timeout`, `.Invalid` | unchanged — caller owns nothing |

**Always check the return value.** On non-Ok, `out^` is unchanged (nil) — do not proceed.

### interrupt — unblock a waiting receiver

```odin
mbox_interrupt :: proc(mb: ^Mailbox) -> IntrResult
```

Wakes one thread waiting in `mbox_wait_receive`. The receiver returns `.Interrupted`.

The interrupted flag is **self-clearing**: `mbox_wait_receive` clears it when it returns `.Interrupted`. A subsequent call to `mbox_wait_receive` will block normally.

| Result | Meaning |
|--------|---------|
| `.Ok` | flag set, waiter will wake |
| `.Closed` | mailbox is already closed — no effect |
| `.Already_Interrupted` | flag already set — no effect |

Use interrupt to signal a receiver without closing the mailbox. Useful for:
- Graceful cancellation that expects a round-trip acknowledgement
- Waking a receiver to re-check external state

```odin
// Sender thread — wake the receiver without closing the mailbox
switch mbox_interrupt(&master.inbox) {
case .Ok:
    // flag set — receiver will return .Interrupted on next wait_receive
case .Closed:
    // mailbox already closed — receiver is gone
case .Already_Interrupted:
    // already signalled — receiver hasn't woken yet, no need to signal again
}
```

```odin
// Receiver loop — .Interrupted does not deliver a message, just wakes the loop
for {
    m: Maybe(^PolyNode)
    switch mbox_wait_receive(&mb, &m) {
    case .Ok:
        defer pool_put(&p, &m)
        // ... process item as normal ...

    case .Interrupted:
        // Woken without a message — check external state, then loop back
        if reload_needed.load() {
            reload_config()
        }
        // Next mbox_wait_receive blocks normally — flag is self-clearing

    case .Closed:
        return  // shutdown

    case .Timeout, .Already_In_Use, .Invalid:
        // handle error conditions
    }
}
```

> Key points: `.Interrupted` delivers no message — `m` remains nil. The receiver must loop
> back to `mbox_wait_receive`. The interrupted flag is self-clearing — no explicit reset needed.
> Use a shared atomic or channel to communicate *what* changed; interrupt only says "go look".

### close

```odin
mbox_close :: proc(mb: ^Mailbox) -> list.List
```

- Marks mailbox as closed. Further `mbox_send` returns `.Closed`.
- Wakes all threads waiting in `mbox_wait_receive` — they return `.Closed`.
- Returns all items still in the queue as a `list.List`.
- Returns an empty list if already closed — idempotent.

**Caller must drain the returned list.** Walk via `list.pop_front`, cast each `^list.Node` to `^PolyNode`, dispose:

```odin
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)
    m: Maybe(^PolyNode) = poly
    flow_dispose(policy.ctx, alloc, &m)
}
```

The cast `(^PolyNode)(raw)` is safe because every item in the mailbox has `PolyNode` at offset 0 — the `list.Node` field that `list.List` tracks is the first field of `PolyNode`.

---

## Pool API

Pool holds reusable items. Type-erased — operates on `^PolyNode` only.
Pool is mechanism only. All lifecycle decisions (allocation, backpressure, disposal) live in `FlowPolicy`.

### Types

```odin
Pool :: struct {
    ...............
}

Pool_Get_Mode :: enum {
    Recycle_Or_Alloc, // check free-list first; call factory if empty
    Alloc_Only,       // always call factory; ignore free-list
    Recycle_Only,     // free-list only; return Pool_Empty if empty — never allocates
}

Pool_Get_Result :: enum {
    Ok,             // success — out^ set to item
    Pool_Empty,     // Recycle_Only: free-list empty; pool_recycle_wait: timeout expired
    Out_Of_Memory,  // factory returned nil
    Closed,         // pool is not active (destroyed or not yet initialized)
    Already_In_Use, // out^ != nil on entry — caller still holds an item
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
pool_get :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, out: ^Maybe(^PolyNode)) -> Pool_Get_Result
```

| Mode | Behavior |
|------|----------|
| `.Recycle_Or_Alloc` | check free-list; call `on_get` on hit; call `factory` on miss |
| `.Alloc_Only` | always call `factory`; skip free-list |
| `.Recycle_Only` | free-list only; return `.Pool_Empty` if empty — never allocates |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `out^` set to item |
| `.Pool_Empty` | `.Recycle_Only` and free-list is empty |
| `.Out_Of_Memory` | factory returned nil (allocation failed) |
| `.Closed` | pool is not active — `pool_init` not yet called or `pool_destroy` already called |
| `.Already_In_Use` | `out^` was non-nil on entry — caller still holds an item |

### recycle_wait — block until item available

```odin
pool_recycle_wait :: proc(p: ^Pool, id: int, out: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

Equivalent to `pool_get(.Recycle_Only)` but with blocking. Never calls `factory` — only recycles from the free-list.

| `timeout` | Behavior |
|-----------|----------|
| `== 0` | non-blocking — returns `.Pool_Empty` immediately if free-list is empty |
| `< 0` | blocks forever — waits until an item of this `id` is put back or pool is closed |
| `> 0` | blocks up to the duration — returns `.Pool_Empty` on expiry |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `out^` set to item |
| `.Pool_Empty` | free-list empty (non-blocking or timeout expired) |
| `.Closed` | pool is not active, or `pool_destroy` called while waiting — all waiters wake and receive `.Closed` |
| `.Already_In_Use` | `out^` was non-nil on entry — caller still holds an item |

```odin
// Thread waiting for a token from a bounded pool
m: Maybe(^PolyNode)
switch pool_recycle_wait(&p, int(FlowId.Token), &m, -1) {
case .Ok:
    defer pool_put(&p, &m)
    // ... use token ...
case .Closed:
    return  // pool is gone — shut down
case .Pool_Empty:
    // timeout expired (only if timeout > 0) — retry or give up
case .Out_Of_Memory, .Already_In_Use:
    // handle error
}
```

> Key point: `pool_recycle_wait` never calls `factory` — it only recycles from the free-list.
> If `pool_destroy` is called while a thread is waiting, all waiters wake and receive `.Closed`.

### put — return to pool

```odin
pool_put :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Exact algorithm — in this order:

1. Check `m.?.id`:
   - `id == 0` → **PANIC** (zero is always invalid, system-wide)
   - `id not in ids[]` → **PANIC** (not registered in this pool — programming error)
2. Get `in_pool_count` for this id (under lock, then unlock)
3. Call `policy.on_put(ctx, alloc, in_pool_count, m)` — **outside lock**
4. If `m^` is still non-nil → push to free-list, increment count, set `m^ = nil` (under lock)

**After `pool_put` returns, `m^` is always nil.** Either recycled (step 4) or consumed by `on_put` (step 3). The panic in step 1 means no silent "what happens on unknown id" — it crashes immediately.

> **Closed pool:** If `pool_destroy` has been called, `pool_put` calls `policy.dispose` (or `free`) and
> sets `m^ = nil`. It does not panic. Items are not silently leaked.

### defer pool_put — when is it safe?

```odin
m: Maybe(^PolyNode)
if pool_get(&p, id, .Recycle_Or_Alloc, &m) == .Ok {
    defer pool_put(&p, &m)  // safety net
    // ... work ...
}
```

Three outcomes when `defer pool_put` fires:
- `m^ == nil` (item was transferred via `mbox_send`) → `pool_put` is a no-op
- `m^ != nil` (item was not transferred) → `pool_put` recycles or `on_put` disposes
- `m^ != nil` with unknown id or zero id → `pool_put` panics — programming error, surfaces immediately

**Safe for valid ids. Panics on unknown or zero id.** The panic is the correct behavior — it tells you exactly where the bug is.

### put_all — return a chain

```odin
pool_put_all :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Walks the linked list starting at `m^`, calling `pool_put` on each node.
Panics on zero or unknown id in any node (same as `pool_put`).
Used to drain a chain of items — typically after `mbox_close` returns remaining in-flight items:

```odin
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)
    m: Maybe(^PolyNode) = poly
    pool_put(&p, &m)  // or flow_dispose if pool is already destroyed
}
```

---

## ID System

### Rules

- Every item id must be > 0 (zero is reserved/invalid, system-wide)
- `pool_init` accepts the complete set of valid ids for this pool
- `pool_put` panics on `id == 0` and on id not in the pool's registered set
- `mbox_send` returns `.Invalid` if `m^.id == 0`
- `factory` stamps `node.id` at allocation time
- Id values are user-defined integer constants — typically from an enum

### Why panic on unknown id?

A foreign id on `pool_put` is almost always a bug: wrong cast earlier, wrong pool, memory corruption, or use-after-free. Silent recycling would create silent starvation or use-after-free later. A loud panic during development is far cheaper than hunting ghosts in production.

Zero is always invalid because it is the zero value of `int` — an uninitialized `PolyNode` would have `id == 0`. Panicking on zero catches missing `factory` stamps immediately.

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

## FlowPolicy Hooks — Reference

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

## Full Lifecycle Example

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

if pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) != .Ok {
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
    return  // mailbox closed or interrupted — m^ is unchanged (nil)
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
// Sender side — close mailbox, drain remaining items
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)          // safe: PolyNode is at offset 0 of every item
    m: Maybe(^PolyNode) = poly
    flow_dispose(policy.ctx, alloc, &m)
}

// destroy pool — calls policy.dispose on all items in free-list
pool_destroy(&p)
```

---

## Pre-allocating (Seeding the Pool)

To avoid runtime latency, pre-allocate before starting threads:

```odin
pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, alloc)

for _ in 0..<100 {
    m: Maybe(^PolyNode)
    if pool_get(&p, int(FlowId.Chunk), .Alloc_Only, &m) == .Ok {
        pool_put(&p, &m)  // put back immediately — goes to free-list
    }
}
```

`Alloc_Only` skips the free-list and always calls `factory`. Here we use it to force 100 fresh allocations into the pool.

---

## Pool Get Modes

Mode is a per-call parameter of `pool_get`. Not a pool-wide setting.

```odin
// Normal operation — recycle if available, allocate if not
pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m)

// Force allocation — use for seeding or when you want a guaranteed fresh item
pool_get(&p, int(FlowId.Chunk), .Alloc_Only, &m)

// Recycle only — use in no-alloc paths (e.g. interrupt handlers)
// Returns .Pool_Empty if free-list is empty — never allocates
if pool_get(&p, int(FlowId.Chunk), .Recycle_Only, &m) != .Ok {
    // free-list was empty — handle: skip, back off, or signal producer
}
```

---

## Invariants

| # | Invariant | Consequence of violation |
|---|-----------|--------------------------|
| I1 | `m^` is the ownership bit. Non-nil = you own it. | Double-free or leak. |
| I2 | All hooks called outside pool mutex. | Guaranteed by pool. User may hold their own locks inside hooks. |
| I3 | `on_get` is called on every recycled item before it reaches caller. | No stale data leaks into new lifecycle. |
| I4 | Pool maintains per-id `in_pool_count`. Passed to `factory` and `on_put`. | Enables accurate backpressure. |
| I5 | `id == 0` on `pool_put` or `mbox_send` → immediate panic or `.Invalid`. | Programming errors surface immediately, not silently. |
| I6 | Unknown id on `pool_put` → immediate panic. | Programming errors surface immediately, not silently. |
| I7 | `on_put`: if `m^ != nil` after hook → pool MUST add to free-list. | Invariant. If hook wants to discard, it must set `m^ = nil`. |

---

## What itc owns vs what you own

### itc owns

- `PolyNode` shape — `node` + `id`
- `^Maybe(^PolyNode)` ownership contract across all APIs
- Pool modes per `pool_get` call
- Hook dispatch — `factory` / `on_get` / `on_put` / `dispose` called with `ctx`
- Guarantee: hooks called outside pool mutex
- `pool_put` — always sets `m^ = nil` after return (or panics on unknown/zero id)
- `mbox_close` — returns remaining chain as `list.List`, caller must drain

### You own

- Id enum definition (`FlowId`)
- All `FlowPolicy` hook implementations
- Locking inside hooks — pool makes no constraints on hook internals
- Per-id count limits — expressed in `on_put`
- Byte-level limits — maintain a counter in `ctx`, call `flow_dispose` when over limit
- Receiver switch logic and casts
- Returning every item to pool — via `pool_put`, `flow_dispose`, or `mbox_send`
