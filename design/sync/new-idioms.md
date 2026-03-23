# Idioms Reference

Quick reference for matryoshka idioms.
Each idiom has a short tag for grep.

These are not laws. No one is forced to follow them.
They are patterns that worked. Take what helps, ignore the rest.

---

## Foundational paradigms

Three ideas underpin the entire library. Everything else is a consequence of these three.

### Intrusive

The queue node lives **inside** the item. No separate allocation. No pointer indirection to a wrapper.

```
non-intrusive:             intrusive:
┌─────────┐               ┌──────────────────┐
│ Node    │──► │ Item │   │ Item             │
│  next   │               │   node.next ──►  │
└─────────┘               │   ... data ...   │
                         A └──────────────────┘
```

The queue is linked via embedded nodes directly. The item IS the node carrier.
Zero-copy is a consequence: only pointers travel, never data.

`PolyNode` is the intrusive node for matryoshka.

```odin
PolyNode :: struct {
    using node: list.Node, // Intrusive link for MPMC free-lists
    id:   int,        // Type discriminator (stamped by factory)
}
```

`PolyNode` provides the queue link (`next`) and the `id` discriminator that tells user code what concrete type is behind the pointer.

Every participant type embeds `PolyNode` at offset 0:

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

`using` at each level promotes fields upward:
- `chunk.next` == `chunk.poly.next`
- `chunk.id`   == `chunk.poly.id`

Whether participant types carry additional nodes for other queues does not matter.
itc only requires `PolyNode` at offset 0.

---

### Type-erased

Pool and mailbox operate on `^PolyNode` only. They are the pipe.
They know nothing about `Chunk`, `Progress`, `FlowId`, or any user type.

All concrete type knowledge — casting, switching, disposing correctly — lives in **user code**.

This is the same pattern Odin uses throughout its standard library:

| Odin stdlib | Type-erased handle | User restores type |
|---|---|---|
| `thread.create` | `data: rawptr` | `(^Master)(data)` in thread proc |
| `mem.Allocator` | `data: rawptr` | procedure table routes by mode |
| `context.user_ptr` | `rawptr` | caller casts |
| matryoshka pool | `^PolyNode` | user casts via `node.id` |
| matryoshka mailbox | `^PolyNode` | user casts via `node.id` |

`PolyNode` is a structured `rawptr` — a pointer plus a discriminator.
The discriminator (`id`) is what makes the cast safe on the user side.

**Separation of concerns:**

```
itc responsibility:
  - queue mechanics (intrusive list)
  - ^Maybe(^PolyNode) ownership contract
  - id list validation at get and put
  - hooks dispatch — factory/on_get/on_put/dispose called with ctx, routed by id
  - strict id validation — unknown id on pool_put causes panic

user responsibility:
  - id enum definition
  - FlowPolicy implementations — factory/on_get/on_put/dispose per id
  - casting ^PolyNode to concrete type after receive
  - switching on node.id — receiver dispatch
  - pool return after processing
  - dispose when item leaves the system permanently
```

---

### `^Maybe(^PolyNode)` — ownership contract

All pointer transfers use `^Maybe(^PolyNode)`. Same signature everywhere: get, send, put, dispose.
One variable. Whole lifetime. Misuse detected at every boundary.

**On entry to any transfer API:**
- `m == nil` — nil pointer to Maybe itself. Defensive. No-op, returns error.
- `m^ == nil` — empty Maybe. Caller has nothing. No-op, returns error.
- `m^ != nil` — caller holds a pointer. Proceed.

**On exit:**
- Success — `m^ = nil`. Transfer complete. Caller must not touch the pointer.
- Failure (closed, full, timeout) — `m^` unchanged. Caller still holds it.
- Failure (internal error) — `m^ = nil`. Pointer consumed. Caller must not touch it.

**APIs that follow this contract:**
- `pool_get` — fills `m^` with a fresh or recycled item
- `mbox_send` — transfers `m^` to mailbox queue, sets `m^ = nil` on success
- `pool_put` — validates id (panics if unknown), calls on_put hook, then pushes to free-list if m^ != nil. m^ is always nil after return.
- Call `flow_dispose(ctx, alloc, &m)` to permanently free an item (shutdown, drain, or byte-limit exceeded).

**Result:** One variable, one check, same meaning everywhere.

```odin
if m^ != nil { /* I hold it — my responsibility */ }
if m^ == nil { /* transferred — not my problem anymore */ }
```

---

## The Golden Rules

### Rule 1 — one variable, whole lifetime

**Mantra:** One convention across all transfer points. Same variable, whole lifetime, misuse detected at every boundary.

1. **`^Maybe(^PolyNode)` replaces raw pointer returns:** Wherever an item is acquired or transferred (`get`, `receive`), it is passed as a parameter, not returned.
2. **Check on Entry:** Every proc checks `m^ != nil` on entry. If the caller still holds an item, it returns `.Already_In_Use`. This prevents overwriting valid data.
3. **One Variable:** The caller uses a single variable from `get` → `send` → `wait_receive` → `put` → `dispose`.

### Rule 2 — every item must be returned

Every item acquired from the pool must be returned. No exceptions. No detours.

Three valid endings for any item:

```
pool_put(&p, &m)                       // recycle — normal path after processing
flow_dispose(policy.ctx, alloc, &m)    // destroy — shutdown or byte limit exceeded
mbox_send(&mb, &m)                     // transfer — receiver will put or dispose
```

There is no fourth option. A forgotten item starves the pool silently over time.

Every case branch of the receiver switch must end with one of these three:

```odin
switch FlowId(m.?.id) {
case .Chunk:
    process(...)
    pool_put(&p, &m)      // must not forget

case .Progress:
    update(...)
    pool_put(&p, &m)      // must not forget
}
// no case exits without returning the item
```

### Lifecycle in one variable

```odin
m: Maybe(^PolyNode)

// 1. Acquire
if pool_get(&pool, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) {
    defer pool_put(&pool, &m) // [itc: defer-put] no-op if transferred

    // 2. Use — cast to concrete type
    c := (^Chunk)(m.?)
    c.len = fill(c.data[:])

    // 3. Transfer
    if mbox_send(&mb, &m) != .Ok {
        return // send failed — m^ unchanged, defer pool_put recycles
    }
    // send success: m^ = nil — defer pool_put is a no-op
}

// 4. Loop
// On next iteration, pool_get can be called again.
```

---

## Building blocks

matryoshka has five object types. Every concurrent system built with this library uses them.

### Master

Master is the actor. It has the logic.

Master is not a library type — it is a pattern you define. A Master struct owns all pools, mboxes, and the allocator for a group of related threads. It decides when to get items, when to send, when to receive, when to shut down.

- One proc creates and initializes Master (allocates pools and mboxes).
- One proc destroys it (closes mboxes, drains, destroys pools, joins threads).
- Master is heap-allocated so threads can hold `^Master` safely. See `heap-master`.

Why heap-allocated? If Master lives on a stack and that proc returns while threads are still running, all `^Master` pointers held by threads become invalid. Heap allocation gives Master a lifetime not tied to any stack frame.

Master owns the allocator. Factory receives it via `ctx`. Items stamp node.id on allocation. pool_put validates it against the registered ids set — panics on mismatch.

```odin
Master :: struct {
    allocator: mem.Allocator,   // owned — passed to hooks via ctx
    pool:      Pool,
    mbox:      Mailbox,
    // ...
}
```

Allocator flow:
```
Master.allocator
    → hooks.ctx = &master
        → factory(ctx, id)
            → m := (^Master)(ctx)
            → item.allocator = m.allocator
                → item.allocator is passed to FlowPolicy hooks (e.g., on_put) for policy decisions
```

### Thread

A thread is a container. It runs one Master proc and nothing else.

```odin
worker :: proc(data: rawptr) {
    m := (^Master)(data)  // [itc: thread-container]
    master_run(m)         // all logic is here, in Master
}
```

- A thread proc receives one `rawptr`. It casts it to `^Master` and calls the master's run proc.
- The thread declares no pools, mboxes, or items of its own.
- All logic — getting items, sending, receiving, deciding — is in Master.

Why so thin? A thread that declares ITC participants as locals creates pointers that escape its stack frame. When the proc returns, those pointers become invalid. Keeping threads thin removes this class of bug.

**Threads as items**: because a thread is just a container, it can itself be an item in a pool. A pool of worker threads is a valid and common pattern.

### Item

An item is any reusable object managed by a pool.

Two kinds:
- **Plain item**: a struct with no internal heap resources. `free` destroys it completely.
- **Disposable item**: a struct that owns internal heap resources (strings, slices, sub-allocations). `free` alone leaks those resources. Needs a `dispose` proc.

Every item embeds `PolyNode` at offset 0 via `using`. The pool and mailbox see only `^PolyNode`. User code casts to the concrete type after receiving.

Items are not limited to data payloads. An item can be a connection, a buffer, a task descriptor — or a thread. The pool does not care what is inside.

### Pool

A pool holds a set of reusable items. It is type-erased — it operates on `^PolyNode` only.

- Master calls `pool_get` to borrow an item, `pool_put` to return it.
- `pool_get` takes an `id` and a `mode` — `id` selects the concrete type to allocate, `mode` selects the allocation strategy.
- `FlowPolicy` (containing `ctx` and `factory`, `on_get`, `on_put`, `dispose` hooks) tells the pool how to manage the item lifecycle. `on_get` is used for sanitizing recycled items. `ctx` is forwarded to every hook call, carrying the allocator and any other needed state.
- Unknown id passed to pool_put causes an immediate panic — programming errors surface immediately.
- pool_init registers the set of valid ids for this pool. All ids must be != 0.

### Mbox (Mailbox)

A mailbox moves a `^PolyNode` from one Master to another. It is type-erased — it operates on `^PolyNode` only.

- Sender calls `mbox_send` with `^Maybe(^PolyNode)`. On success, inner pointer becomes nil — transfer complete.
- Receiver calls `mbox_wait_receive` (blocking) or `mbox_try_receive_batch` (non-blocking). Receiver gets `^PolyNode`, reads `node.id`, casts to concrete type.
- `mbox_close` atomically empties the queue and returns the head of the remaining list as `^PolyNode`. Caller is forced to drain and dispose — no silent leak possible.

```odin
// shutdown — mbox_close returns remaining items, caller drains via flow_dispose
head := mbox_close(&mb)
node := head
for node != nil {
    next := node.next
    m: Maybe(^PolyNode) = node
    flow_dispose(policy.ctx, alloc, &m)    // routes by node.id via FlowPolicy.dispose
    node = next
}
```

Why `mbox_close` returns the list? The caller is forced to handle remaining items whether they want to or not. No choice means no silent leak. Same principle as `^Maybe(^PolyNode)` — misuse is impossible to ignore.

### How they fit together

Masters are the actors. Threads run them. Items flow between Masters via Mboxes, recycled by Pools.

```
Thread A                         Thread B
  └─ Master A                      └─ Master B
       │                                 │
       ├─ Pool (type-erased)              │
       │    └─ get(id, mode)             │
       │         └─ ^PolyNode            │
       │              └─ cast to Chunk   │
       │                   └─ fill       │
       │                        └─ send ─┤
       │                                 ├─ wait_receive → ^PolyNode
       │                                 ├─ switch node.id
       │                                 ├─ cast to concrete type
       │                                 └─ pool_put → recycle
       │
       └─ shutdown: mbox_close → returns list → flow_dispose each → pool_destroy
```

### ITC participant

"ITC participant" is a shorthand used throughout this document.
It means: any object shared between threads — a Pool, Mbox, or Loop.
ITC participants always live in Master, never on a thread's stack.

---

## Marker scheme

Each idiom has a short tag. The tag appears as a comment at the relevant line in code:

```
// [itc: <tag>]
```

Examples:
```odin
m: Maybe(^PolyNode)     // [itc: maybe-container]
defer pool_destroy(&p)  // [itc: defer-destroy]
```

To find all usages of one idiom:
```
grep -r "\[itc: maybe-container\]" examples/ tests/
```

To find all marked lines:
```
grep -r "\[itc:" examples/ tests/
```

Where to find this documentation: `design/idioms.md`

---

## Core invariants

- **Ownership**: transfer heap pointers via `^Maybe(^PolyNode)`. On success, inner is nil — transfer complete. On failure, inner is unchanged — caller retains the pointer.
- **Must return**: every item acquired from the pool must be returned — via `pool_put`, `flow_dispose`, or `mbox_send`. No exceptions.
- **Intrusive**: every item embeds `PolyNode` (which has a `next` pointer) at offset 0. No separate node allocation. Queue is linked via embedded nodes.
- **Type-erased**: pool and mailbox operate on `^PolyNode` only. All concrete type knowledge lives in user code.
- **Lifecycle**: items with internal resources use `factory`/`on_get`/`on_put`/`dispose`. Register them in `FlowPolicy`. Pool calls them automatically with `ctx`, routed by `node.id`.
- **Concurrency**: ITC participants live in heap-allocated structs. Thread procs hold only a pointer to the owner struct.

---

## Quick reference

| Tag | Name | One line |
|-----|------|----------|
| `maybe-container` | Maybe as container | Keep item in `Maybe(^PolyNode)` from get to transfer. Never extract raw pointer. |
| `defer-put` | scope-exit safety net | Use defer pool_put(&p, &m). Always safe: pool_put always sets m^ = nil (or panics on invalid id). |
| `dispose-contract` | dispose hook signature | A `dispose` hook takes `(ctx, alloc, ^Maybe(^PolyNode))`. Routes by `id`. Register in `FlowPolicy`. Call directly as `flow_dispose(ctx, alloc, &m)`. |
| `poly-item` | poly item full lifecycle | Items embed PolyNode at offset 0. Pool allocates per id. Receiver switches on node.id. Every case returns item. |
| `mbox-close-drain` | drain after close | `mbox_close` returns remaining list. Walk list, call `flow_dispose` on each node. |
| `on-get-hygiene` | `on_get` for hygiene | `on_get` is called on every recycled item. Use it to zero or sanitize the item for reuse. |
| `dispose-optional` | dispose is advice | For permanent disposal (shutdown or drain), call `flow_dispose(ctx, alloc, &m)` directly. For normal recycle paths, use `pool_put`. |
| `heap-master` | heap-allocated master | Heap-allocate the struct that owns ITC participants when shared with spawned threads. |
| `thread-container` | thread is a container | A thread proc only casts `rawptr` to `^Master`. No ITC participants as stack locals. |
| `errdefer-dispose` | conditional defer for factory | Use named return + `defer if !ok { dispose(...) }` when a proc creates and returns a master. |
| `defer-destroy` | destroy at scope exit | Register `defer destroy` for pools/mboxes/loops to guarantee shutdown in all paths. |
| `poly-hooks` | `FlowPolicy` for poly items | Define `factory`/`on_get`/`on_put`/`dispose` as a `::` constant. Set `ctx` at runtime. |
| `on-put-backpressure`| Per-ID Count Limiting | Use the `on_put` hook with `in_pool_count` to implement backpressure by consuming items. |

---

## Ownership model

### `maybe-container` — Maybe as container

**Problem**: You have a `^PolyNode` from `pool_get`. You want to pass it to `send` safely.

**Fix**: Keep it in `Maybe(^PolyNode)` from acquisition to transfer. Never extract the raw pointer into a second variable.

```odin
// [itc: maybe-container]
m: Maybe(^PolyNode)
if pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) {
    defer pool_put(&p, &m)               // safety net if send fails
    if mbox_send(&mb, &m) != .Ok {
        return                           // send failed — m^ unchanged, defer recycles
    }
}
// m^ is nil on success — transfer complete, defer pool_put is a no-op
```

---

### `dispose-contract` — dispose hook signature contract

**Problem**: An item has internal heap resources. You need a hook to free them all safely.

**Fix**: Write a dispose hook that follows the `(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode))` contract, routes by `node.id`, and registers it in `FlowPolicy`.

```odin
// [itc: dispose-contract]
// this is a hook — registered in FlowPolicy, called by pool internally
flow_dispose :: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode)) {
    if m == nil  { return }
    if m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:
        c := (^Chunk)(node)
        free(c, alloc)
    case .Progress:
        p := (^Progress)(node)
        free(p, alloc)
    }
    m^ = nil
}

// call site — call directly
flow_dispose(policy.ctx, alloc, &m)    // call directly
```

**Contract**:
- Takes `ctx: rawptr`, `alloc: mem.Allocator`, and `^Maybe(^PolyNode)`. Nil inner is a no-op. Sets inner to nil on return.
- Routes cleanup by `node.id` — each concrete type freed correctly.
- Must be safe to call after partial init. All cleanup steps handle zero-initialized fields.
- Register as `FlowPolicy.dispose`. Call directly using `flow_dispose(ctx, alloc, &m)`.

---

### `defer-dispose` — defer with pool_put

**Problem**: You fill an item before sending. If send fails, you need to clean up.

**Fix**: Register `pool_put` via `defer` immediately after acquisition. If `m^` is non-nil at scope exit, `pool_put` recycles the item or the `on_put` hook disposes it.

```odin
m: Maybe(^PolyNode)
if pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) {
    defer pool_put(&p, &m)              // [itc: defer-put]

    c := (^Chunk)(m.?)
    c.len = fill(c.data[:])
    if mbox_send(&mb, &m) != .Ok {
        return // send failed — m^ unchanged, defer pool_put recycles
    }
    // send success → m^ = nil → pool_put is a no-op
}
```

**One owner rule**: never copy `m^` into a second `Maybe`. Two `Maybe` variables pointing to the same `^PolyNode` means two potential dispose calls on the same memory.

---

### `errdefer-dispose` — conditional defer for factory procs

**Problem**: A factory proc creates a master. If setup fails halfway, partially-init state must be cleaned up.

**Fix**: Use a named return `ok` and `defer if !ok { dispose(...) }`.

```odin
// [itc: errdefer-dispose]
create_master :: proc() -> (m: ^Master, ok: bool) {
    raw := new(Master)
    if !master_init(raw) { free(raw); return }
    m_opt: Maybe(^Master) = raw
    defer if !ok { master_dispose(&m_opt) }

    // ... more setup ...
    m = raw
    ok = true; return
}
```

---

### `dispose-optional` — dispose is advice

**Problem**: `flow_dispose` is never called automatically by mailbox. Only the caller does it. It is easy to forget.

**Fix**: For permanent disposal (shutdown or drain), call `flow_dispose(ctx, alloc, &m)` directly. For normal recycle paths, use `pool_put`.

```odin
// [itc: dispose-optional]
// You call flow_dispose when the item will not be recycled.
```

---

## Object lifecycle / pool model

### `poly-item` — poly item full lifecycle

**Problem**: Items in the same flow carry different concrete data. A single typed pool cannot handle them.

**Fix**: Embed `PolyNode` at offset 0 in every participant type. One pool with a registered id list. Factory allocates the correct concrete type per id. Receiver switches on `node.id`.

```odin
// id enum and union — defined once by user, next to each other
FlowId :: enum int { Chunk = 1, Progress = 2 }

// participant types — PolyNode at offset 0 via using
Chunk :: struct {
    using poly: PolyNode,   // offset 0
    data: [CHUNK_SIZE]byte,
    len:  int,
}

Progress :: struct {
    using poly: PolyNode,   // offset 0
    percent: int,
}

// pool init — ctx set at runtime, proc pointers from compile-time constant
policy := FLOW_POLICY
policy.ctx = &master
pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, master.allocator)

// Producer:                                           // [itc: poly-item]
m: Maybe(^PolyNode)
if pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) {
    defer pool_put(&p, &m)                                     // [itc: defer-put]
    c := (^Chunk)(m.?)
    c.len = fill(c.data[:])
    if mbox_send(&mb, &m) != .Ok {
        return // send failed — m^ unchanged, defer pool_put recycles
    }
}


// Consumer:
m2: Maybe(^PolyNode)
if mbox_wait_receive(&mb, &m2) != .Ok {
    return // mailbox closed
}
defer pool_put(&p, &m2)                                    // [itc: defer-put]
switch FlowId(m2.?.id) {
case .Chunk:
    c := (^Chunk)(m2.?)
    process_chunk(c)
    pool_put(&p, &m2)                                  // [itc: defer-put]
case .Progress:
    pr := (^Progress)(m2.?)
    update_progress(pr)
    pool_put(&p, &m2)
}
```

**Rules**:
- `PolyNode` must be the first field of every participant type. Offset 0 is required for the cast to be valid.
- `using` on `PolyNode` promotes `id` and link fields directly onto the struct.
- Receiver switch is user code. itc delivers `^PolyNode` and the `id`. User casts, processes, returns to pool.
- No compile-time checking from itc. All checks are runtime.

---

### `defer-put` — every item must be returned

**Problem**: After receiving and processing an item, it is easy to forget to return it. A forgotten item starves the pool silently over time.

**Fix**: Every case branch of the receiver switch must end with `pool_put`, `flow_dispose`, or `mbox_send`. There is no fourth option.

```odin
m: Maybe(^PolyNode)
if mbox_wait_receive(&mb, &m) != .Ok {
    return // mailbox closed
}
defer pool_put(&p, &m)      // [itc: defer-put] — safety net only

switch FlowId(m.?.id) {
case .Chunk:
    process(...)
    pool_put(&p, &m)            // [itc: defer-put] — normal recycle path

case .Progress:
    update(...)
    pool_put(&p, &m)            // [itc: defer-put] — normal recycle path
}
// no case exits without returning the item
```

**The three valid endings**:
- `pool_put(&p, &m)` — recycle, normal path
- `flow_dispose(ctx, alloc, &m)` — destroy, for shutdown or byte-limit exceeded
- `mbox_send(&mb, &m)` — transfer, receiver will put or dispose

`defer pool_put` is a safety net — it fires only if `pool_put` was not reached. It should never be the primary disposition path in the receiver switch.

---

### Safety guarantee — panic on unknown id

`pool_put` panics immediately if the item's id is not in the pool's registered id set.
This is by design: an unknown id is a programming error, not a recoverable condition.
Returning the item silently would mask the bug.

```odin
pool_put(&p, &m)
// m^ is always nil here — pool_put always consumes the item (or panics)
```

---

### `mbox-close-drain` — drain after close

**Problem**: `mbox_close` returns remaining items. They must be disposed. Forgetting leaks memory.

**Fix**: Walk the returned list. Call `flow_dispose` on each node.

```odin
// [itc: mbox-close-drain]
head := mbox_close(&mb)
node := head
for node != nil {
    next := node.next
    m: Maybe(^PolyNode) = node
    flow_dispose(policy.ctx, alloc, &m)    // routes by node.id via FlowPolicy.dispose
    node = next
}
```

Use `flow_dispose` (not `pool_put`) in drain loops: during shutdown, items should be destroyed, not recycled into the pool.

**Why `mbox_close` returns the list?**
No choice — caller is forced to handle remaining items. Misuse is impossible to ignore.

---

**Problem**: It is easy to confuse `on_get` (for reuse) with `dispose` (for permanent cleanup).

**Fix**: Keep them separate. `on_get` sanitizes for reuse; `dispose` frees permanently. Both are routed by `node.id`.

| Hook      | When called                       | What it does                                                                       |
|-----------|-----------------------------------|------------------------------------------------------------------------------------|
| `factory` | On `pool_get` miss                | Allocates correct concrete type per id, stamps `node.id`.                          |
| `on_get`  | On `pool_get` hit (recycle)       | Clears stale state for reuse. Never frees internal resources.                      |
| `on_put`  | On `pool_put`                     | Hook for backpressure. Can consume the item to prevent it from being recycled.     |
| `dispose` | On pool_destroy (shutdown)        | Routes by node.id, frees internal resources, frees struct, sets m^ = nil.         |

```odin
// factory: allocates per id via ctx — ctx carries Master or allocator
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

// on_get: clears state for reuse — never frees     // [itc: on-get-hygiene]
flow_on_get :: proc(ctx: rawptr, m: ^Maybe(^PolyNode)) {
    if m == nil || m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:    (^Chunk)(node).len = 0
    case .Progress: (^Progress)(node).percent = 0
    }
}

// dispose: frees everything permanently            // [itc: dispose-contract]
flow_dispose :: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode)) {
    if m == nil  { return }
    if m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:
        c := (^Chunk)(node)
        free(c, alloc)
    case .Progress:
        p := (^Progress)(node)
        free(p, alloc)
    }
    m^ = nil
}
```

---

### `poly-policy` — FlowPolicy for poly items

**Problem**: A pool must allocate, sanitize, and dispose multiple concrete types correctly. Scattering this logic leads to leaks.

**Fix**: Define the `factory`/`on_get`/`on_put`/`dispose` hooks as a `::` compile-time `FlowPolicy` constant. Set `ctx` at runtime before passing to `pool_init`. Pool forwards `ctx` to every hook call.

```odin
// compile-time — proc pointers only, ctx set at runtime
FLOW_POLICY :: FlowPolicy{                // [itc: poly-policy]
    factory = flow_factory,   // allocates per id via ctx
    on_get  = flow_on_get,    // reuse hygiene per id
    on_put  = flow_on_put,    // backpressure hook
    dispose = flow_dispose,   // permanent free per id
}

// runtime — ctx points to Master (or any user state)
policy := FLOW_POLICY
policy.ctx = &master

pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, master.allocator)
```

**Rules**:
- All four proc fields are optional. nil = default behavior.
- `ctx` is runtime — cannot be set in a `::` constant. Set it before passing the policy to `pool_init`.
- `factory` receives `ctx`, `alloc`, `id`, `in_pool_count` — allocates the correct concrete type, stamps `node.id`.
- `on_get` receives `ctx` and `^Maybe(^PolyNode)` — must NOT free internal resources.
- `on_put` receives `ctx`, `alloc`, `in_pool_count`, `^Maybe(^PolyNode)` — implements backpressure.
- `dispose` receives `ctx`, `alloc`, and `^Maybe(^PolyNode)` — routes by `node.id`, frees everything.
- If you use `factory`, also use `dispose`. They are the create/destroy pair.

---

### `on-put-backpressure` — Per-ID Count Limiting

**Problem**: Different item types need different recycling limits. A single pool max cannot express per-id policies.

**Fix**: Implement the `on_put` hook. The pool passes the current `in_pool_count` for the item's id. The hook can then decide whether to recycle the item or consume it to enforce a limit.

```odin
// [itc: on-put-backpressure]
flow_on_put :: proc(ctx: rawptr, alloc: mem.Allocator, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    if m == nil || m^ == nil { return }
    #partial switch FlowId(m.?.id) {
    case .Chunk:
        if in_pool_count > 400 {
            // too many chunks, dispose this one
            flow_dispose(ctx, alloc, m) // m^ will be nil after this
        }
    case .Progress:
        if in_pool_count > 128 {
            // too many progress indicators, dispose this one
            flow_dispose(ctx, alloc, m) // m^ will be nil after this
        }
    }
    // If m^ is still non-nil after on_put, pool MUST add to free-list.
    // To prevent recycling, hook must call flow_dispose (sets m^ = nil).
}
```

**Rules**:
- Called outside pool lock — safe to read any state in `ctx`.
- Pool passes count for this specific id — not total pool count.
- To reject an item, the hook must fully dispose of it and ensure `m^` is `nil`.
- If `on_put` is `nil`, the pool always recycles items.
- For byte-level limits, the user must maintain a counter in `ctx` and decide whether to call `pool_put` or `flow_dispose(ctx, alloc, &m)` themselves.

### Pool get modes

Mode is a per-call parameter of `pool_get`. Not a pool policy.

```odin
pool_get(&p, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) // free list first, allocate if empty
pool_get(&p, int(FlowId.Chunk), .Alloc_Only,       &m) // always allocate, ignore free list
pool_get(&p, int(FlowId.Chunk), .Recycle_Only,     &m) // free list only, error if empty
```

| Mode                 | Behavior                                          |
|----------------------|---------------------------------------------------|
| `.Recycle_Or_Alloc`  | take from free list if available, allocate if empty |
| `.Alloc_Only`        | always allocate, never touch free list          |
| `.Recycle_Only`      | free list only, error if empty — never allocates  |

---

## Concurrency structure

### `heap-master` — ITC participants in a heap-allocated struct

**Problem**: Threads must not reference stack memory of a proc that might exit.

**Fix**: `new(Master)` — heap-allocate the owner. Call `dispose` after joining all threads.

```odin
m := new(Master)  // [itc: heap-master]
if !master_init(m) { free(m); return false }
// ... spawn threads passing m ...
// ... join threads ...
m_opt: Maybe(^Master) = m
master_dispose(&m_opt)
```

---

### `thread-container` — thread is just a container for its master

**Problem**: Pointers to thread-local stack participants escape the thread's frame.

**Fix**: Move all ITC participants into the master struct. Thread proc only casts `rawptr` to `^Master`.

```odin
proc(data: rawptr) {
    c := (^Master)(data)  // [itc: thread-container]
    // thread owns nothing — ITC objects live in Master
}
```

---

### `defer-destroy` — destroy resources at scope exit

**Problem**: Pools, mailboxes, or loops must be shut down in all paths to prevent leaks or deadlocks.

**Fix**: Register `destroy` with `defer` immediately after successful initialization.

```odin
mbox_init(&mb)
defer mbox_destroy(&mb)  // [itc: defer-destroy]

// Assumes `master` is a struct with `allocator` field and `FLOW_POLICY` is defined
policy := FLOW_POLICY
policy.ctx = &master
pool_init(&p, policy, {int(FlowId.Chunk), int(FlowId.Progress)}, master.allocator)
defer pool_destroy(&p)
```

**Why**: Cleanup runs in early returns. Shutdown logic stays near init.

---

## Addendums

### Foundational patterns

#### Lock release safety — `defer-unlock`

**Problem**: Lock acquired but function exits early → deadlock risk.
**Fix**: Register `defer unlock` immediately after lock acquisition.

```odin
sync.mutex_lock(&m)
defer sync.mutex_unlock(&m)
```

**Rule**: This is a foundational Odin pattern. In `matryoshka`, **never mark it with a tag** in the source code. It is documented here for reference only.

### Advice & Best Practices

1. **`defer-destroy`**:
   - Always use this for `Pool` and `Mailbox` instances owned by the current scope.
   - If the resource is part of a `Master` struct, the `master_dispose` proc handles the destroy calls.

2. **`defer-put`**:
   - Register immediately after `pool_get`. Never wait until after filling the item.
   - One dispose per one live `Maybe(^PolyNode)`. Never copy `m^` into a second `Maybe` — two owners, two potential frees, one corruption.

3. **Foundational `defer-unlock`**:
   - Never call `mbox_send` or `pool_get` (blocking) while holding a custom lock — deadlock risk.

### loop_mbox and nbio_mbox

- `loop_mbox` = loop + any wakeup (semaphore, custom, or anything)
- `nbio_mbox` = loop + nbio wakeup (a special case of `loop_mbox`)

`nbio_mbox.init_nbio_mbox` creates a `loop_mbox.Mbox` with an nbio-specific `WakeUper`.
All `loop_mbox` procs work on the returned pointer: `send`, `try_receive_batch`, `close`, `destroy`.

### Open item — backpressure

Backpressure should inform what gets allocated — chunks, jobs, etc.
When the system is under pressure, the `id` passed to `pool_get` may change
based on downstream capacity signals.
To be designed separately.

---

*There are several ways to skin a cat. These idioms are one way. Use what works for you.*
