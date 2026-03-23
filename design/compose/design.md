# matryoshka — Normative Specification

====================================================
Author notes - read, analyze, ask questions, proceed
====================================================



---------------------------------------
IF NOTE ABOVE GENERIC - ADD IT TO RULES
---------------------------------------

====================================================


> **This is the single source of truth.**
> All API signatures, contracts, and rules are defined here.
> When this file contradicts any other document — this file wins.

Cross-reference: [Golden Contract](../sync/golden-contract.md) — read it first if you haven't.

---

## Spiral

itc is a Matryoshka — nested layers, each complete on its own.

You enter at the layer you need.
You stop when you have enough.
You go deeper only when the next layer solves a real problem you have right now.

| Layer | What you have | What you don't need yet |
|-------|--------------|------------------------|
| 1 | `PolyNode` + `Maybe` | everything else |
| 2 | + hooks (`ctor`, `dtor`) | pool, mailbox |
| 3 | + simple pool (wrapper around hooks) | extended pool, mailbox |
| 4 | + extended pool (free-list, flow control) | mailbox |
| 5 | + mailbox | — full itc |

**The rule:** move to the next layer because you need it — not because it is there.

> This is an internal design principle, not user documentation.
> When writing examples, docs, or new features — always ask:
> which is the minimum layer this belongs to?

---

## Document Writing Rules

When editing this document, follow these rules:

**Sentences**
- One idea per line.
- Split compound sentences — do not chain clauses with commas.

**Lists**
- Use bullet lists for sets of items, attributes, or steps.
- Use numbered lists only when order is contractually significant.

**Sequential steps**
- Write as a bullet list, not as a run-on sentence.
- Label the context: `Send side:` / `Receive side:` / `Algorithm:` etc.

**Tables**
- Use for result codes, mode behavior, and rules.
- Keep column count minimal — two or three columns maximum.

**Prose paragraphs**
- Reserve for motivation and explanation, not for API contracts.
- API contracts go in tables or bullet lists.

**Source files**
- Source files know nothing about layers — no layer references in comments or docs.
- No forward references to terms not yet defined in the document.
- Always use the two-value form to read the inner value of a `Maybe`: `ptr, ok := m.?`
- Never use the single-value form `ptr := m.?` — it panics if nil.
- Never cast or dereference around `.?`.

---

## What is itc?

Empty by intent.

---

## Decision Log

None. Place for new decisions.

---

## Core Type

```odin
import list "core:container/intrusive/list"

PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int,       // must be != 0, describe different types of user data
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

`using` magic:
- `chunk.id == chunk.poly.id`
- `chunk.next == chunk.poly.next`

**Offset 0 rule** — enforced by convention.
The cast `(^Chunk)(node)` is valid only if `PolyNode` is first.
itc has no compile-time check for this.

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

With `using poly: PolyNode` at offset 0, your struct *is* the node.
No wrapper. No extra allocation. No extra pointer hop.

`PolyNode` is itc's intrusive node.
Pool and Mailbox operate on `^PolyNode` — which is also `^YourStruct` when offset 0 holds.
The cast is safe because you placed `PolyNode` first.

`list.Node` has exactly one `prev` and one `next`.
Linking an item into two lists simultaneously corrupts both.
An item lives in exactly one place at a time — enforced by the link structure, not by a flag.

### Type Erased

Pool and Mailbox do not know what types they carry.
They receive `^PolyNode`, store `^PolyNode`, return `^PolyNode`.
They are pipes.

All concrete type knowledge lives in user code — in `on_get`, `on_put`, and in the receiver's `switch` statement.

`PolyNode.id` is the discriminator that makes the cast safe.

This is the same pattern Odin's stdlib uses throughout:
- `thread.create` takes `data: rawptr`
- `context.user_ptr` is `rawptr`
- `mem.Allocator` passes `rawptr`.

The type disappears at the boundary and reappears in the implementation.

```odin
// Pool side — type-erased
pool_get(&p, int(FlowId.Chunk), .Available_Or_New, &m)  // returns ^PolyNode

// User side — typed
c := (^Chunk)(m.?)   // safe because on_get stamped id = FlowId.Chunk and placed PolyNode at offset 0
```

The id is the contract:
- Zero is always invalid.
- Unknown id panics.
- Known id → safe cast.

### ^Maybe(^PolyNode) — ownership at the API boundary

Every itc API passes items as `^Maybe(^PolyNode)`.
The `Maybe` value tracks who owns the item right now.

```
m: Maybe(^PolyNode)

m^ == nil                       m^ != nil
┌───────────┐                   ┌───────────┐
│    nil    │  ← not yours      │   ptr ────┼──► [ PolyNode | your fields ]
└───────────┘                   └───────────┘
                                     you own this — must transfer, recycle, or dispose
```

**Transfer via `mbox_send`:**

```
before send                     after send
┌───────────┐                   ┌───────────┐
│   ptr ────┼──► [item]         │    nil    │   [item] → now in mailbox queue
└───────────┘                   └───────────┘
  m^ != nil (yours)               m^ == nil (transferred)
```

**Receive via `mbox_wait_receive`:**

```
before receive                  after receive
┌───────────┐                   ┌───────────┐
│    nil    │                   │   ptr ────┼──► [item]   ← dequeued from mailbox
└───────────┘                   └───────────┘
  out^ == nil (empty)             out^ != nil (yours now)
```

Two levels, two mechanisms:
- **`list.Node`** — structural: one `prev`/`next`, a node cannot be in two queues at once
- **`Maybe`** — contractual: nil/non-nil tells every API call who holds the item right now

---

## Participants

itc has five participant roles.
Only one of them — **Master** — knows concrete types.

### Items

User-defined structs with `PolyNode` embedded at offset 0 via `using`.
Examples:
- `Chunk`
- `Progress`
- `Command`

Items travel through the system as `^PolyNode`.
Only the Master that allocated or received them casts back to the concrete type.

```odin
Chunk :: struct {
    using poly: PolyNode,   // offset 0 — required
    data: [CHUNK_SIZE]byte,
    len:  int,
}
```

### Pool

A type-erased recycler:
- Holds free items as `^PolyNode`
- Hands them out via `pool_get`
- Takes them back via `pool_put`
- Knows nothing about what is inside the items

All lifecycle logic is delegated to `PoolHooks` callbacks that live in user code:
- allocation
- reset
- flow control
- disposal

### Mailbox

A type-erased transporter.
Moves `^PolyNode` from one Master to another across thread boundaries.
Blocking, with optional timeout.
Supports interrupt and close.

Mailbox knows nothing about item types.
It holds ownership during transit and releases it to the receiver on success.

### Master

A user struct that runs on a thread.
The only participant that knows concrete types.

Master owns the pools and mailboxes that belong to its domain.

Send side:
- calls `pool_get` to acquire an item
- fills it
- sends via `mbox_send`

Receive side:
- calls `mbox_wait_receive`
- switches on `id`
- casts to concrete type
- processes
- returns via `pool_put`

Master lives on the heap. It is the unit of work in itc.

```odin
Master :: struct {
    pool:  Pool,
    inbox: Mailbox,
    // ... other mailboxes, state, allocator ...
}
```

### Thread

A thin container that runs exactly one Master.
It holds only `^Master`.
It declares no itc objects itself — those belong to Master.

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

**Why ownership matters here:**
- Mailbox and Pool are opaque — they cannot track what type they hold.
- Master is the only actor that can safely cast `^PolyNode` back to a concrete type.
- Only one Master should hold a given item at any moment.
- The `^Maybe(^PolyNode)` contract (nil = you don't own it) is enforced at every API boundary.

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

### Typed allocation to Maybe

Allocate the concrete type, stamp it, then wrap in `Maybe` once.

```odin
ev := new(Event)
ev.poly.id = int(ItemId.Event)
ev.code    = 99
m: Maybe(^PolyNode) = &ev.poly
// [itc: typed-to-maybe] — Maybe is the sole owner; do NOT defer free(ev).
```

Rules:
- Once wrapped in `Maybe`, the `Maybe` is the sole owner.
- Do NOT `defer free` on the original typed variable.
- For cleanup on failure: dispose manually using your allocator and set `m^ = nil`.

> **Note for hook implementors.**
> In full itc, this pattern appears only inside `on_get` implementations.
> User code calls `pool_get` — never `new` directly.
> `on_get` allocates (when `m^==nil`), stamps id, and sets `m^`; the pool returns it to the caller.
> Outside of hooks, this is not a user-code pattern.

---

→ Full table in [Golden Contract](../sync/golden-contract.md).

---

## Mailbox API

Mailbox moves items between Masters (threads).
Type-erased — operates on `^PolyNode` only.

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

**Always check the return value.**
On non-Ok, the item is still yours — dispose or retry.

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

**Always check the return value.**
On non-Ok, `out^` is unchanged (nil) — do not proceed.

### interrupt — unblock a waiting receiver

```odin
mbox_interrupt :: proc(mb: ^Mailbox) -> IntrResult
```

Wakes one thread waiting in `mbox_wait_receive`.
The receiver returns `.Interrupted`.

The interrupted flag is **self-clearing**:
- `mbox_wait_receive` clears it when it returns `.Interrupted`.
- A subsequent call to `mbox_wait_receive` will block normally.

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

Key points:
- `.Interrupted` delivers no message — `m` remains nil.
- The receiver must loop back to `mbox_wait_receive`.
- The interrupted flag is self-clearing — no explicit reset needed.
- Use a shared atomic or channel to communicate *what* changed; interrupt only says "go look".

### close

```odin
mbox_close :: proc(mb: ^Mailbox) -> list.List
```

- Marks mailbox as closed. Further `mbox_send` returns `.Closed`.
- Wakes all threads waiting in `mbox_wait_receive` — they return `.Closed`.
- Returns all items still in the queue as a `list.List`.
- Returns an empty list if already closed — idempotent.

**Caller must drain the returned list.**
Walk via `list.pop_front`, cast each `^list.Node` to `^PolyNode`, dispose:

```odin
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)
    m: Maybe(^PolyNode) = poly
    pool_put(&master.pool, &m)  // return to pool; if pool closed, m^ stays non-nil — dispose manually
}
```

The cast `(^PolyNode)(raw)` is safe because:
- Every item in the mailbox has `PolyNode` at offset 0.
- The `list.Node` field that `list.List` tracks is the first field of `PolyNode`.

---

## Pool API

Pool holds reusable items.
Type-erased — operates on `^PolyNode` only.
Mechanism only — all lifecycle decisions live in `PoolHooks`:
- allocation
- flow control
- disposal

### Types

```odin
Pool :: struct {
    ...............
}

Pool_Get_Mode :: enum {
    Available_Or_New,  // existing item if available, otherwise create
    New_Only,          // always create
    Available_Only,    // existing item only — no creation, on_get not called if none stored
}

Pool_Get_Result :: enum {
    Ok,            // item returned in out^
    Not_Available, // Available_Only: no item stored — on_get was not called
    Not_Created,   // on_get ran and returned nil — may be deliberate or failure
    Closed,        // pool is closed
}
```

### PoolHooks

```odin
PoolHooks :: struct {
    ctx:    rawptr,  // user context — carries master or any state; allocator too if hooks need it
                     // may be nil — pool passes it as-is
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}
```

**`ctx` is runtime** — cannot be set in a `::` compile-time constant.
Set it before calling `pool_init`.

Both proc fields are required.

### Init / Close

```odin
pool_init  :: proc(p: ^Pool, hooks: ^PoolHooks, ids: []int)
pool_close :: proc(p: ^Pool) -> (list.List, ^PoolHooks)
```

`ids`: complete set of valid item ids for this pool. All must be != 0. Non-empty.

`pool_close` contract:

```odin
nodes, h := pool_close(&p)
```

- Returns all items currently stored in the pool as `list.List`.
- Returns `^PoolHooks` — the pointer passed to `pool_init`.
- Post-close `pool_get`/`pool_put` return `.Closed` or no-op.
- Pool does not call `on_put` during close. User drains manually.

### Pool borrows hooks — heap Master pattern

`pool_init` takes `^PoolHooks`. Pool stores the pointer. User keeps the struct.

`Master` is always heap-allocated. `newMaster` and `freeMaster` are always written together — they are a pair.

```odin
Master :: struct {
    pool:  Pool,
    hooks: PoolHooks,
    alloc: mem.Allocator,
    ...
}

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.hooks = PoolHooks{
        ctx    = m,
        on_get = master_on_get,
        on_put = master_on_put,
    }
    pool_init(&m.pool, &m.hooks, ids)
    return m
}

freeMaster :: proc(master: ^Master) {
    nodes, _ := pool_close(&master.pool)
    // NOTE: dispose nodes before freeing other Master resources — dispose code may use Master fields.
    for {
        raw := list.pop_front(&nodes)
        if raw == nil { break }
        // dispose node — master knows how
    }
    alloc := master.alloc
    free(master, alloc)
}
```

`ctx` is set at runtime. Do not set it in a compile-time constant.

### get — acquire ownership

```odin
pool_get :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, out: ^Maybe(^PolyNode)) -> Pool_Get_Result
```

| Mode | Behavior |
|------|----------|
| `.Available_Or_New` | check free-list; call `on_get` on hit or miss |
| `.New_Only` | always call `on_get` with `m^==nil`; skip free-list |
| `.Available_Only` | free-list only; return `.Not_Available` if empty — `on_get` not called |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `out^` set to item |
| `.Not_Available` | `.Available_Only` and no item stored — `on_get` was not called |
| `.Not_Created` | `on_get` ran and returned nil — may be deliberate or failure |
| `.Closed` | pool is closed |

### get_wait — block until item available

```odin
pool_get_wait :: proc(p: ^Pool, id: int, out: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

Equivalent to `pool_get(.Available_Only)` but with blocking.
Never calls `on_get` — only waits for an item to be stored.

`pool_get_wait` with timeout = 0 is the same as `pool_get` with `Available_Only`.

| `timeout` | Behavior |
|-----------|----------|
| `== 0` | non-blocking — returns `.Not_Available` immediately if no item stored |
| `< 0` | blocks forever — waits until an item of this `id` is put back or pool is closed |
| `> 0` | blocks up to the duration — returns `.Not_Available` on expiry |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `out^` set to item |
| `.Not_Available` | no item stored (non-blocking or timeout expired) |
| `.Closed` | pool is closed, or `pool_close` called while waiting — all waiters wake and receive `.Closed` |

```odin
// Thread waiting for a token from a bounded pool
m: Maybe(^PolyNode)
switch pool_get_wait(&p, int(FlowId.Token), &m, -1) {
case .Ok:
    defer pool_put(&p, &m)
    // ... use token ...
case .Closed:
    return  // pool is gone — shut down
case .Not_Available:
    // timeout expired (only if timeout > 0) — retry or give up
}
```

Key points:
- `pool_get_wait` never calls `on_get` — it only waits for stored items.
- If `pool_close` is called while a thread is waiting, all waiters wake and receive `.Closed`.

### put — return to pool

```odin
pool_put :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Algorithm — in this order:

1. Check `m.?.id`:
   - `id == 0` → **PANIC** (zero is always invalid, system-wide)
   - `id not in ids[]` → **PANIC** (not registered in this pool — programming error)
2. Get `in_pool_count` for this id (under lock, then unlock)
3. Call `hooks.on_put(ctx, in_pool_count, m)` — **outside lock**
4. If `m^` is still non-nil → push to free-list, increment count, set `m^ = nil` (under lock)

Open pool → `on_put` decides: hook sets `m^=nil` (disposed) or leaves `m^!=nil` (stored).

The panic in step 1 means no silent "what happens on unknown id" — it crashes immediately.

> **Closed pool + valid id:** `pool_put` returns with `m^` still non-nil. Caller owns the item.
> Must dispose manually. Does not panic. Items are not silently leaked.

### defer pool_put — when is it safe?

```odin
m: Maybe(^PolyNode)
if pool_get(&p, id, .Available_Or_New, &m) == .Ok {
    defer pool_put(&p, &m)  // safety net
    // ... work ...
}
```

Three outcomes when `defer pool_put` fires:
- `m^ == nil` (item was transferred via `mbox_send`) → `pool_put` is a no-op
- `m^ != nil` (item was not transferred) → `pool_put` recycles or `on_put` disposes
- `m^ != nil` with unknown id or zero id → `pool_put` panics — programming error, surfaces immediately

Safe for valid ids.
Panics on unknown or zero id.
The panic is the correct behavior — it tells you exactly where the bug is.

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
    pool_put(&master.pool, &m)  // if pool closed, m^ stays non-nil — dispose manually
}
```

---

## ID System

### Rules

- Every item id must be != 0 (zero is reserved/invalid, system-wide)
- `pool_init` accepts the complete set of valid ids for this pool
- `pool_put` panics on `id == 0` and on id not in the pool's registered set
- `mbox_send` returns `.Invalid` if `m^.id == 0`
- `on_get` stamps `node.id` at allocation time — `on_get` is one allocator, not the only one; the user sets id
- Id values are user-defined integer constants — typically from an enum

### Why panic on unknown id?

A foreign id on `pool_put` is almost always a bug:
- wrong cast earlier
- wrong pool
- memory corruption
- use-after-free

Silent recycling would create silent starvation or use-after-free later.
A loud panic during development is far cheaper than hunting ghosts in production.

Zero is always invalid because it is the zero value of `int`.
An uninitialized `PolyNode` would have `id == 0`.
Panicking on zero catches missing `on_get` id stamps immediately.

### Example

```odin
FlowId :: enum int {
    Chunk    = 1,  // must be != 0
    Progress = 2,
}

// Registration at pool_init
pool_init(&p, &hooks, {int(FlowId.Chunk), int(FlowId.Progress)})
```

---

## PoolHooks — Reference

All hooks are called **outside the pool mutex**.
This is guaranteed.
Hooks may safely access `ctx` — which may contain application-level locks — without deadlock risk.

### on_get

```odin
on_get :: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode))
```

Pool calls `on_get` on every `pool_get` — except `Available_Only` when no item is stored.

| Entry state | Meaning | Hook must |
|-------------|---------|-----------|
| `m^ == nil` | no item available | create a new item, set `node.id = id`, set `m^` |
| `m^ != nil` | recycled item | reinitialize for reuse |

`in_pool_count`: number of items with this `id` currently idle (stored) in the pool — not total live objects. Hook may use it to decide whether to create or not.

After `on_get`:

| Exit state | Meaning |
|------------|---------|
| `m^ != nil` | item ready — pool returns `.Ok` to caller |
| `m^ == nil` | pool returns `.Not_Created` to caller |

`.Not_Created` is not always an error. Hook may return nil on purpose.

`id` is always passed — needed for creation. Can also be read from `node.id` on recycle, but passing it avoids the cast.

```odin
master_on_get :: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    master := (^Master)(ctx)
    if m^ == nil {
        // no item available — create new one using master.alloc
        switch FlowId(id) {
        case .Chunk:
            c := new(Chunk, master.alloc)
            c.id = id
            m^ = (^PolyNode)(c)
        case .Progress:
            p := new(Progress, master.alloc)
            p.id = id
            m^ = (^PolyNode)(p)
        }
    } else {
        // recycled item — reinitialize using master fields
        node := m^
        switch FlowId(node.id) {
        case .Chunk:    (^Chunk)(node).len = 0
        case .Progress: (^Progress)(node).percent = 0
        }
    }
}
```

### on_put

```odin
on_put :: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode))
```

Called during `pool_put`, outside lock.

- `in_pool_count`: current count of items with this id currently idle (stored) in the pool — not total live objects. Use it to decide flow control.
- If hook sets `m^ = nil` → item is disposed. Pool will not store it.
- If hook leaves `m^ != nil` → pool stores it.

```odin
master_on_put :: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    master := (^Master)(ctx)
    if m == nil || m^ == nil { return }
    node := m^
    #partial switch FlowId(node.id) {
    case .Chunk:
        if in_pool_count > 400 {
            free((^Chunk)(node), master.alloc)
            m^ = nil  // dispose — pool will not store
        }
    case .Progress:
        if in_pool_count > 128 {
            free((^Progress)(node), master.alloc)
            m^ = nil  // dispose — pool will not store
        }
    }
    // m^ still non-nil here → pool stores it
}
```

---

## Full Lifecycle Example

Sender and receiver are in separate threads. `m` variables are different.

### Setup

```odin
FlowId :: enum int { Chunk = 1, Progress = 2 }

// Master is heap-allocated — newMaster/freeMaster are always written together
master := newMaster(context.allocator)
defer freeMaster(master)

mbox_init(&mb)
```

### Sender

```odin
m: Maybe(^PolyNode)

if pool_get(&master.pool, int(FlowId.Chunk), .Available_Or_New, &m) != .Ok {
    return  // not created or pool closed
}
defer pool_put(&master.pool, &m)  // safety net: fires if send fails

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
defer pool_put(&master.pool, &m)  // safety net — fires if switch case exits early

switch FlowId(m.?.id) {
case .Chunk:
    c := (^Chunk)(m.?)
    process_chunk(c)
    pool_put(&master.pool, &m)    // explicit return — m^ = nil — defer is no-op

case .Progress:
    pr := (^Progress)(m.?)
    update_progress(pr)
    pool_put(&master.pool, &m)    // explicit return — m^ = nil — defer is no-op

// no case exits without returning the item
}
```

**Why both `defer pool_put` and per-case `pool_put`?**

- Per-case `pool_put` is the normal path — it sets `m^ = nil`.
- After that, the deferred `pool_put` fires and sees `m^ == nil` — becomes a no-op.
- The `defer` is a safety net for paths you did not anticipate: added cases, early returns, panics in process procs.
- Belt and suspenders — intentional.

### Shutdown

```odin
// Sender side — close mailbox, drain remaining in-flight items
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)          // safe: PolyNode is at offset 0 of every item
    m: Maybe(^PolyNode) = poly
    pool_put(&master.pool, &m)        // on_put may dispose; closed pool leaves m^ non-nil — handle below
    if m^ != nil {
        // pool was already closed — dispose manually
        // master.on_put was not called — free directly
    }
}

// freeMaster closes pool, drains pool free-list, frees all resources
freeMaster(master)
```

---

## Pre-allocating (Seeding the Pool)

To avoid runtime latency, pre-allocate before starting threads:

```odin
master := newMaster(context.allocator)

for _ in 0..<100 {
    m: Maybe(^PolyNode)
    if pool_get(&master.pool, int(FlowId.Chunk), .New_Only, &m) == .Ok {
        pool_put(&master.pool, &m)  // put back immediately — goes to free-list
    }
}
```

`New_Only` always calls `on_get` with `m^==nil`, forcing creation even when items are stored.
Used here to pre-allocate 100 fresh items into the pool.

---

## Pool Get Modes

Mode is a per-call parameter of `pool_get`. Not a pool-wide setting.

```odin
// Normal operation — use stored item if available, create if not
pool_get(&master.pool, int(FlowId.Chunk), .Available_Or_New, &m)

// Force creation — use for seeding or when you want a guaranteed fresh item
pool_get(&master.pool, int(FlowId.Chunk), .New_Only, &m)

// Stored only — use in no-alloc paths (e.g. interrupt handlers)
// Returns .Not_Available if no item stored — on_get not called
if pool_get(&master.pool, int(FlowId.Chunk), .Available_Only, &m) != .Ok {
    // no item stored — handle: skip, back off, or call pool_get_wait
}
```

---

## Invariants

| # | Rule | Consequence of violation |
|---|------|--------------------------|
| R1 | `m^` is the ownership bit. Non-nil = you own it. | Double-free or leak. |
| R2 | All callbacks called outside pool mutex. | Guaranteed by pool. User may hold their own locks inside callbacks. |
| R3 | `on_get` is called on every `pool_get` except `Available_Only` when no item stored. | Hook handles both create (`m^==nil`) and reinitialize (`m^!=nil`). |
| R4 | Pool maintains per-id `in_pool_count`. Passed to `on_get` and `on_put`. | Enables flow control. |
| R5 | `id == 0` on `pool_put` or `mbox_send` → immediate panic or `.Invalid`. | Programming errors surface immediately, not silently. |
| R6 | Unknown id on `pool_put` → immediate panic. | Programming errors surface immediately, not silently. |
| R7 | `on_put`: if `m^ != nil` after hook → pool stores it. If `m^ == nil` → pool discards. | Hook sets `m^ = nil` to dispose. |
| R8 | Always use `ptr, ok := m.?` to read the inner value of `Maybe(^PolyNode)`. Never use the single-value form `ptr := m.?`. | Single-value form panics if nil — in concurrent code that is an unrecoverable crash. |
| R9 | `ctx` must outlive the pool. Do not tie `ctx` to a stack object or any resource freed before `pool_close`. | Hook called after `ctx` freed → use-after-free. |

---

## What itc owns vs what you own

### itc owns

- `PolyNode` shape — `node` + `id`
- `^Maybe(^PolyNode)` ownership contract across all APIs
- Pool modes per `pool_get` call
- Hook dispatch — `on_get` / `on_put` called with `ctx`
- Guarantee: hooks called outside pool mutex
- `pool_put` — always sets `m^ = nil` after return (or panics on unknown/zero id)
- `mbox_close` — returns remaining chain as `list.List`, caller must drain

### You own

- Id enum definition (`FlowId`)
- All `PoolHooks` hook implementations
- Locking inside hooks — pool makes no constraints on hook internals
- Per-id count limits — expressed in `on_put`
- Byte-level limits — maintain a counter in `ctx`, dispose in `on_put` when over limit
- Receiver switch logic and casts
- Returning every item to pool — via `pool_put` or `mbox_send`; disposing manually after `pool_close`


## Addendums

### `^Maybe(^PolyNode)` vs `^^PolyNode`

#### Question

Is `^^PolyNode` good enough to replace `^Maybe(^PolyNode)` at API boundaries?

#### Answer: No. They are not equivalent.

---

#### What `^^PolyNode` gives you

A pointer to a pointer. Two nil states:

- `m == nil` — the handle itself is nil (pointer to pointer is null)
- `*m == nil` — the inner pointer is null

No standard unwrap operator. No "valid or not" semantics in the type.

---

#### What `^Maybe(^PolyNode)` adds

Odin's `Maybe(T)` is a tagged union: `union { T, nil }`.

It adds one extra semantic state and the `.?` unwrap operator:

| Expression | `^Maybe(^PolyNode)` | `^^PolyNode` |
|------------|---------------------|--------------|
| `m == nil` | nil handle — programming error | same |
| `m^ == nil` | you do NOT own the item | same (ambiguous — transferred? freed? never set?) |
| `m^ != nil` | you own it | same |
| `ptr, ok := m.?` | safe unwrap, ok==false if nil | not available |
| `m^ = nil` after send | unambiguous: transferred | ambiguous: freed? transferred? |

---

#### The critical difference: transfer signal

With `^^PolyNode`, setting `*m = nil` means the inner pointer is null — nothing more.
It cannot tell the caller whether the item was:

- transferred
- freed
- never allocated
- an error condition

With `^Maybe(^PolyNode)`, `m^ = nil` is the ownership transfer protocol:

- API sets it on success → "I took it, you no longer own it"
- API leaves it on failure → "Still yours, I didn't take it"
- Caller checks it to know whether to free on exit

This is why `defer pool_put(&p, &m)` is safe:
`pool_put` checks `m^ == nil` → no-op if already transferred.
With `^^PolyNode`, you cannot make that check reliably.

---

#### The three-level nil check

```
m == nil      → nil handle        → programming error, return .Invalid
m^ == nil     → inner is nil      → don't own it (transferred or nothing)
m^ != nil     → inner is non-nil  → you own it
```

`^^PolyNode` only has two of these levels.
The distinction between "transferred" and "never had it" collapses.

---

#### Verdict

`^Maybe(^PolyNode)` is NOT syntactic sugar for `^^PolyNode`.

`Maybe` encodes the ownership contract into the type:

- nil inner = not yours
- non-nil inner = yours
- `.?` operator = safe check-and-extract in one step

`^^PolyNode` is a raw memory indirection with no ownership semantics.

The entire itc API — `mbox_send`, `mbox_wait_receive`, `pool_get`, `pool_put` — is built on the three-state nil check.
Replacing `Maybe` with `**` would require adding a separate ownership flag to every call site.

**Keep `^Maybe(^PolyNode)`.**

---

### The `.?` unwrap operator

`Maybe(T)` in Odin is a tagged union: `union { T, nil }`.
`.?` is the unwrap operator. Two forms.

#### Two-value form — use this

```odin
ptr, ok := m.?
```

Safe. No panic.
`ok` is `false` if `m == nil`. `ptr` is only valid when `ok` is `true`.

From `dolls/layer1/tests/hooks/hooks_test.odin`:

```odin
m := fp.ctor(int(ex.ItemId.Event))
ptr, ok := m.?
testing.expect(t, ok,  "Maybe must unwrap")
testing.expect(t, ptr.id == int(ex.ItemId.Event), "ctor must set id")
```

#### Single-value form — big no-no

```odin
ptr := m.?
```

Returns the inner value directly.
**Panics at runtime if `m == nil`.**

You can almost never be sure ownership is confirmed at the point of use.
In concurrent code a panic here means a crash with no recovery.
Do not use this form in itc code.

#### Why `.?` matters at API boundaries

With `^^PolyNode`, dereferencing gives you the pointer — but no attached "was it set intentionally" bit.

With `^Maybe(^PolyNode)`, the tagged union carries that bit.
`.?` exposes it:

| Form | Rule |
|------|------|
| `ptr, ok := m.?` | always use this — check and extract in one step |
| `ptr := m.?` | big no-no — panics if nil |
| `^^PolyNode` | neither form available — raw dereference only |

---

### How to implement `Maybe` "magic" using `^^PolyNode`

You cannot use `^^PolyNode` directly as a drop-in replacement.
To get the same guarantees you have to add a flag by hand.

This is what the equivalent of `^Maybe(^PolyNode)` looks like with raw pointers:

```odin
// Manual equivalent of Maybe(^PolyNode)
Owned :: struct {
    ptr:   ^PolyNode,
    valid: bool,       // the flag Maybe carries for free
}
```

Every call site that now writes:

```odin
m: Maybe(^PolyNode)
ptr, ok := m.?
```

would become:

```odin
m: Owned
if m.valid {
    ptr := m.ptr
    // use ptr
}
```

And every API that now does:

```odin
m^ = nil    // transfer complete
```

would have to do:

```odin
m.ptr   = nil
m.valid = false
```

Every. Single. Call. Site.

You also lose the compiler's help: nothing stops you from reading `m.ptr` while `m.valid == false`.
With `Maybe`, the `.?` operator enforces the check — you cannot get the pointer without going through it.

**Summary:**

| | `^Maybe(^PolyNode)` | `^^PolyNode` + manual flag |
|---|---|---|
| ownership bit | built into the type | you add and maintain it |
| safe extract | `.?` — one step | `if valid { use ptr }` — two steps, error-prone |
| transfer | `m^ = nil` | `m.ptr = nil; m.valid = false` |
| compiler enforces check | yes | no |
| extra memory | discriminant word | `bool` field (same cost, more noise) |
