# Idioms Reference

Quick reference for odin-itc idioms.
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

`PolyNode` is the intrusive node for odin-itc. It is built on `core:container/intrusive` list node:

```odin
PolyNode :: struct {
    using node: intrusive.Node,  // offset 0 — list mechanics live here
    id: int,                     // user-defined — identifies the concrete type
}
```

`intrusive.Node` provides the queue link (`next`, `prev`).
`PolyNode` adds `id` on top — the discriminator that tells user code what concrete type is behind the pointer.

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
- `chunk.next` == `chunk.poly.node.next`
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
| odin-itc pool | `^PolyNode` | user casts via `node.id` |
| odin-itc mailbox | `^PolyNode` | user casts via `node.id` |

`PolyNode` is a structured `rawptr` — a pointer plus a discriminator.
The discriminator (`id`) is what makes the cast safe on the user side.

**Separation of concerns:**

```
itc responsibility:
  - queue mechanics (intrusive list)
  - ^Maybe(^PolyNode) ownership contract
  - id list validation at get and put
  - hooks dispatch — factory/reset/dispose called with ctx, routed by id
  - foreign item detection (id mismatch, allocator mismatch)

user responsibility:
  - id enum definition
  - Pool_Hooks implementations — factory/reset/dispose per id
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
- `pool.get` — fills `m^` with a fresh or recycled item
- `mbox.send` — transfers `m^` to mailbox queue, sets `m^ = nil` on success
- `pool.put` — returns `m^` to free list, sets `m^ = nil` on success
- `pool.dispose` — frees `m^` permanently via hooks, sets `m^ = nil`

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
pool.put(&p, &m)       // recycle — normal path after processing
pool.dispose(&p, &m)   // destroy — shutdown, foreign, or byte limit exceeded
mbox.send(&mb, &m)     // transfer — receiver will put or dispose
```

There is no fourth option. A forgotten item starves the pool silently over time.

Every case branch of the receiver switch must end with one of these three:

```odin
switch FlowId(m.?.id) {
case .Chunk:
    process(...)
    pool.put(&p, &m)      // must not forget

case .Progress:
    update(...)
    pool.put(&p, &m)      // must not forget
}
// no case exits without returning the item
```

### Lifecycle in one variable

```odin
m: Maybe(^PolyNode)

// 1. Acquire
pool.get(&p, &m, int(FlowId.Chunk), .Always)  // returns .Already_In_Use if m^ != nil
defer pool.dispose(&p, &m)                     // [itc: defer-dispose] no-op if transferred

// 2. Use — cast to concrete type
c := (^Chunk)(m.?)
c.len = fill(c.data[:])

// 3. Transfer
mbox.send(&mb, &m)   // m^ = nil on success — dispose becomes no-op
                     // m^ unchanged on failure — dispose cleans up

// 4. Loop
// On next iteration, pool.get verifies m^ is nil.
```

---

## Building blocks

odin-itc has five object types. Every concurrent system built with this library uses them.

### Master

Master is the actor. It has the logic.

Master is not a library type — it is a pattern you define. A Master struct owns all pools, mboxes, and the allocator for a group of related threads. It decides when to get items, when to send, when to receive, when to shut down.

- One proc creates and initializes Master (allocates pools and mboxes).
- One proc destroys it (closes mboxes, drains, destroys pools, joins threads).
- Master is heap-allocated so threads can hold `^Master` safely. See `heap-master`.

Why heap-allocated? If Master lives on a stack and that proc returns while threads are still running, all `^Master` pointers held by threads become invalid. Heap allocation gives Master a lifetime not tied to any stack frame.

Master owns the allocator. Factory receives it via `ctx`. Items stamp it on allocation so `pool.put` can detect foreign items.

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
                → pool.put checks item.allocator via ctx
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

- Master calls `pool.get` to borrow an item, `pool.put` to return it.
- `pool.get` takes an `id` and a `mode` — `id` selects the concrete type to allocate, `mode` selects the allocation strategy.
- `Pool_Hooks` (ctx / factory / reset / dispose) tells the pool how to manage the item lifecycle. `ctx` is forwarded to every hook call — carries the allocator and any other needed state.
- Foreign items (id mismatch or allocator mismatch) are returned to the caller for disposal.

### Mbox (Mailbox)

A mailbox moves a `^PolyNode` from one Master to another. It is type-erased — it operates on `^PolyNode` only.

- Sender calls `mbox.send` with `^Maybe(^PolyNode)`. On success, inner pointer becomes nil — transfer complete.
- Receiver calls `mbox.wait_receive` (blocking) or `mbox.try_receive_batch` (non-blocking). Receiver gets `^PolyNode`, reads `node.id`, casts to concrete type.
- `mbox.close` atomically empties the queue and returns the head of the remaining list as `^PolyNode`. Caller is forced to drain and dispose — no silent leak possible.

```odin
// shutdown — close returns remaining items, caller drains via pool.dispose
head := mbox.close(&mb)
node := head
for node != nil {
    next := node.next
    m: Maybe(^PolyNode) = node
    pool.dispose(&p, &m)    // pool routes by node.id, uses its own hooks
    node = next
}
```

Why `close` returns the list? The caller is forced to handle remaining items whether they want to or not. No choice means no silent leak. Same principle as `^Maybe(^PolyNode)` — misuse is impossible to ignore.

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
       │                                 └─ pool.put → recycle
       │
       └─ shutdown: mbox.close → returns list → pool.dispose each → pool.destroy
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
defer pool.destroy(&p)  // [itc: defer-destroy]
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
- **Must return**: every item acquired from the pool must be returned — via `pool.put`, `pool.dispose`, or `mbox.send`. No exceptions.
- **Intrusive**: every item embeds `PolyNode` (which embeds `intrusive.Node`) at offset 0. No separate node allocation. Queue is linked via embedded nodes.
- **Type-erased**: pool and mailbox operate on `^PolyNode` only. All concrete type knowledge lives in user code.
- **Lifecycle**: items with internal resources use factory/reset/dispose/accept. Register them in `Pool_Hooks`. Pool calls them automatically with `ctx`, routed by `node.id`.
- **Concurrency**: ITC participants live in heap-allocated structs. Thread procs hold only a pointer to the owner struct.

---

## Quick reference

| Tag | Name | One line |
|-----|------|----------|
| `maybe-container` | Maybe as container | Keep item in `Maybe(^PolyNode)` from get to transfer. Never extract raw pointer. |
| `defer-put` | must return to pool | Every item must be returned via pool.put, pool.dispose, or mbox.send. No exceptions. |
| `dispose-contract` | dispose hook signature | A dispose hook takes `(ctx: rawptr, m: ^Maybe(^PolyNode))`. Routes by `node.id`. Nil inner is a no-op. Register in Pool_Hooks. Call via `pool.dispose`. |
| `defer-dispose` | defer with pool.dispose | Use `defer pool.dispose(&p, &m)` so cleanup runs in all paths. |
| `poly-item` | poly item full lifecycle | Items embed PolyNode at offset 0. Pool allocates per id. Receiver switches on node.id. Every case returns item. |
| `foreign-dispose` | foreign item | When put returns a foreign pointer, call pool.dispose, not free. |
| `mbox-close-drain` | drain after close | mbox.close returns remaining list. Walk list, call pool.dispose on each node. |
| `reset-vs-dispose` | reset vs dispose | reset clears state for reuse. dispose frees permanently. factory allocates per id. |
| `dispose-optional` | dispose is advice | pool.dispose is never called by mailbox. Caller calls it via defer or drain loop. |
| `heap-master` | heap-allocated master | Heap-allocate the struct that owns ITC participants when shared with spawned threads. |
| `thread-container` | thread is a container | A thread proc only casts rawptr to ^Master. No ITC participants as stack locals. |
| `errdefer-dispose` | conditional defer for factory | Use named return + `defer if !ok { dispose(...) }` when a proc creates and returns a master. |
| `defer-destroy` | destroy at scope exit | Register `defer destroy` for pools/mboxes/loops to guarantee shutdown in all paths. |
| `poly-hooks` | Pool_Hooks for poly items | Define factory/reset/dispose/accept as a :: constant next to the id enum. Set ctx at runtime. |
| `pool-accept` | per-id count limiting | accept(ctx, id, current_count) → bool. nil = always recycle. Pool passes count outside lock. |

---

## Ownership model

### `maybe-container` — Maybe as container

**Problem**: You have a `^PolyNode` from `pool.get`. You want to pass it to `send` safely.

**Fix**: Keep it in `Maybe(^PolyNode)` from acquisition to transfer. Never extract the raw pointer into a second variable.

```odin
// [itc: maybe-container]
m: Maybe(^PolyNode)
pool.get(&p, &m, int(FlowId.Chunk), .Always)
mbox.send(&mb, &m)
// m^ is nil here — transfer complete
```

---

### `dispose-contract` — dispose hook signature contract

**Problem**: An item has internal heap resources. You need a hook to free them all safely.

**Fix**: Write a dispose hook that follows the `(ctx: rawptr, m: ^Maybe(^PolyNode))` contract, routes by `node.id`, and registers it in `Pool_Hooks`. Callers always go through `pool.dispose` — never call the hook directly.

```odin
// [itc: dispose-contract]
// this is a hook — registered in Pool_Hooks, called by pool internally
flow_dispose :: proc(ctx: rawptr, m: ^Maybe(^PolyNode)) {
    if m == nil  { return }
    if m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:
        c := (^Chunk)(node)
        free(c, c.allocator)
    case .Progress:
        p := (^Progress)(node)
        free(p, p.allocator)
    }
    m^ = nil
}

// call site — always via pool, never directly
pool.dispose(&p, &m)    // pool calls flow_dispose(hooks.ctx, &m) internally
```

**Contract**:
- Takes `ctx: rawptr` and `^Maybe(^PolyNode)`. Nil inner is a no-op. Sets inner to nil on return.
- Routes cleanup by `node.id` — each concrete type freed correctly.
- Must be safe to call after partial init. All cleanup steps handle zero-initialized fields.
- Register as `Pool_Hooks.dispose`. Never call directly from user code.

---

### `defer-dispose` — defer with dispose

**Problem**: You fill an item before sending. If send fails, you need to clean up.

**Fix**: Register `pool.dispose` via `defer` immediately after acquisition. Pool calls `hooks.dispose(ctx, &m)` internally — single source of truth, no duplicate logic.

```odin
m: Maybe(^PolyNode)
pool.get(&p, &m, int(FlowId.Chunk), .Always)
defer pool.dispose(&p, &m)          // [itc: defer-dispose]

c := (^Chunk)(m.?)
c.len = fill(c.data[:])
mbox.send(&mb, &m)
// send success → m^ = nil → dispose is no-op
// send failure → m^ non-nil → pool.dispose frees via hooks.dispose(ctx, node.id)
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

**Problem**: `pool.dispose` is never called automatically by mailbox. Only the caller does it. It is easy to forget.

**Fix**: Use `defer pool.dispose(&p, &m)` (`defer-dispose`) or manual drain loops when an item leaves the system permanently.

```odin
// [itc: dispose-optional]
// You call pool.dispose when the item will not be recycled.
```

---

## Object lifecycle / pool model

### `poly-item` — poly item full lifecycle

**Problem**: Items in the same flow carry different concrete data. A single typed pool cannot handle them.

**Fix**: Embed `PolyNode` at offset 0 in every participant type. One pool with a registered id list. Factory allocates the correct concrete type per id. Receiver switches on `node.id`.

```odin
// id enum and union — defined once by user, next to each other
FlowId :: enum { Chunk, Progress }

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
hooks := FLOW_HOOKS
hooks.ctx = &master
pool.init(&p,
    hooks = hooks,
    ids   = {int(FlowId.Chunk), int(FlowId.Progress)},
)

// Producer:                                           // [itc: poly-item]
m: Maybe(^PolyNode)
pool.get(&p, &m, int(FlowId.Chunk), .Always)
defer pool.dispose(&p, &m)                                 // [itc: defer-dispose]
c := (^Chunk)(m.?)
c.len = fill(c.data[:])
mbox.send(&mb, &m)

// Consumer:
m2: Maybe(^PolyNode)
mbox.wait_receive(&mb, &m2)
defer pool.dispose(&p, &m2)                               // [itc: defer-dispose]
switch FlowId(m2.?.id) {
case .Chunk:
    c := (^Chunk)(m2.?)
    process_chunk(c)
    pool.put(&p, &m2)                                  // [itc: defer-put]
case .Progress:
    pr := (^Progress)(m2.?)
    update_progress(pr)
    pool.put(&p, &m2)
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

**Fix**: Every case branch of the receiver switch must end with `pool.put`, `pool.dispose`, or `mbox.send`. There is no fourth option.

```odin
m: Maybe(^PolyNode)
mbox.wait_receive(&mb, &m)
defer pool.dispose(&p, &m)      // [itc: defer-dispose] — safety net only

switch FlowId(m.?.id) {
case .Chunk:
    process(...)
    pool.put(&p, &m)            // [itc: defer-put] — normal recycle path

case .Progress:
    update(...)
    pool.put(&p, &m)            // [itc: defer-put] — normal recycle path
}
// no case exits without returning the item
```

**The three valid endings**:
- `pool.put(&p, &m)` — recycle, normal path
- `pool.dispose(&p, &m)` — destroy, for shutdown or byte-limit exceeded
- `mbox.send(&mb, &m)` — transfer, receiver will put or dispose

`defer pool.dispose` is a safety net — it fires only if `pool.put` was not reached. It should never be the primary disposition path in the receiver switch.

---

### `foreign-dispose` — foreign item

**Problem**: `pool.put` returns a pointer when the item is foreign (id mismatch or allocator mismatch). `free` alone leaks resources.

**Fix**: Call `pool.dispose` on the returned pointer. Pool owns the hooks — it knows how to destroy any item it recognizes.

```odin
foreign := pool.put(&p, &m)
if foreign != nil {
    pool.dispose(&p, &foreign)    // [itc: foreign-dispose] — routes by node.id via hooks
}
```

**Rule**: id mismatch or allocator mismatch → pool cannot recycle → caller calls `pool.dispose`.
Pool validates the id against its registered list before dispatching to hooks.
If the id is not recognized, pool returns the pointer — caller is responsible.

---

### `mbox-close-drain` — drain after close

**Problem**: `mbox.close` returns remaining items. They must be disposed. Forgetting leaks memory.

**Fix**: Walk the returned list. Call `pool.dispose` on each node. Pool owns the hooks — single source of truth for destruction.

```odin
// [itc: mbox-close-drain]
head := mbox.close(&mb)
node := head
for node != nil {
    next := node.next
    m: Maybe(^PolyNode) = node
    pool.dispose(&p, &m)    // routes by node.id via Pool_Hooks.dispose
    node = next
}
```

**Why `pool.dispose` not `flow_dispose`?**
Pool already owns the lifecycle — factory, reset, dispose. Calling `pool.dispose` keeps destruction logic in one place. `flow_dispose` would duplicate it.

**Why `close` returns the list?**
No choice — caller is forced to handle remaining items. Misuse is impossible to ignore.

---

**Problem**: It is easy to confuse `reset` (for reuse) with `dispose` (for permanent cleanup).

**Fix**: Keep them separate. Never free internal resources in `reset`. Both are routed by `node.id`.

| Hook | When called | What it does |
|------|-------------|--------------|
| `factory` | Fresh allocation | Allocates correct concrete type per id, stamps `node.id`, sets allocator |
| `reset` | On recycle | Clears stale state for reuse. Never frees internal resources |
| `dispose` | Permanent destruction | Routes by `node.id`, frees internal resources, frees struct, sets `m^ = nil` |
| `accept` | On put, before recycle | Returns true to recycle, false to treat as foreign. Pool passes current free list count for this id. nil = always recycle |

```odin
// factory: allocates per id via ctx — ctx carries Master or allocator
flow_factory :: proc(ctx: rawptr, id: int) -> (^PolyNode, bool) {
    m := (^Master)(ctx)
    switch FlowId(id) {
    case .Chunk:
        c := new(Chunk, m.allocator)
        if c == nil { return nil, false }
        c.allocator = m.allocator
        c.id = id
        return (^PolyNode)(c), true
    case .Progress:
        p := new(Progress, m.allocator)
        if p == nil { return nil, false }
        p.allocator = m.allocator
        p.id = id
        return (^PolyNode)(p), true
    }
    return nil, false
}

// reset: clears state for reuse — never frees     // [itc: reset-vs-dispose]
flow_reset :: proc(ctx: rawptr, node: ^PolyNode) {
    switch FlowId(node.id) {
    case .Chunk:    (^Chunk)(node).len = 0
    case .Progress: (^Progress)(node).percent = 0
    }
}

// dispose: frees everything permanently            // [itc: dispose-contract]
flow_dispose :: proc(ctx: rawptr, m: ^Maybe(^PolyNode)) {
    if m == nil  { return }
    if m^ == nil { return }
    node := m^
    switch FlowId(node.id) {
    case .Chunk:
        c := (^Chunk)(node)
        free(c, c.allocator)
    case .Progress:
        p := (^Progress)(node)
        free(p, p.allocator)
    }
    m^ = nil
}
```

---

### `poly-hooks` — Pool_Hooks for poly items

**Problem**: A pool must allocate, reset, and dispose multiple concrete types correctly. Scattering this logic leads to leaks.

**Fix**: Define factory/reset/dispose as a `::` compile-time constant next to the id enum. Set `ctx` at runtime before passing to `pool.init`. Pool forwards `ctx` to every hook call.

```odin
// compile-time — proc pointers only, ctx set at runtime
FLOW_HOOKS :: Pool_Hooks{                // [itc: poly-hooks]
    factory = flow_factory,   // allocates per id via ctx
    reset   = flow_reset,     // reuse hygiene per id
    dispose = flow_dispose,   // permanent free per id
}

// runtime — ctx points to Master (or any user state)
hooks := FLOW_HOOKS
hooks.ctx = &master

pool.init(&p,
    hooks = hooks,
    ids   = {int(FlowId.Chunk), int(FlowId.Progress)},
)
```

**Rules**:
- All four proc fields are optional. nil = default behavior.
- `ctx` is runtime — cannot be set in a `::` constant. Set it before passing hooks to `pool.init`.
- `factory` receives `ctx` and `id` — allocates the correct concrete type, stamps `node.id`. Must self-clean on failure. Returns `(nil, false)` on failure.
- `reset` receives `ctx` and `^PolyNode` — must NOT free internal resources.
- `dispose` receives `ctx` and `^Maybe(^PolyNode)` — routes by `node.id`, frees internal resources, frees struct, sets `m^ = nil`.
- `accept` receives `ctx`, `id`, and `current_count` — return true to recycle, false to reject. Called outside pool mutex.
- If you use `factory`, also use `dispose`. They are the create/destroy pair.
- `ctx` carries the allocator — no separate allocator parameter in `pool.init`.

---

### `pool-accept` — per-id count limiting

**Problem**: Different item types need different recycling limits. A single pool max cannot express per-id policies.

**Fix**: Implement `accept` hook. Pool passes the current free list count for the item's id. Hook returns true to recycle, false to treat as foreign (caller disposes).

```odin
// [itc: pool-accept]
flow_accept :: proc(ctx: rawptr, id: int, current_count: int) -> bool {
    switch FlowId(id) {
    case .Chunk:    return current_count < 400   // max 400 chunks in free list
    case .Progress: return current_count < 128   // max 128 progress items
    }
    return false
}
```

**Rules**:
- Called outside pool mutex — safe to read any state in `ctx`.
- Pool passes count for this specific id — not total pool count.
- nil `accept` = always recycle. Default. No limits.
- Limit by count only. Byte-level limits are user responsibility — maintain a byte counter in `ctx` and call `pool.dispose` manually instead of `pool.put` when exceeded.

### Pool get modes

Mode is a per-call parameter of `pool.get`. Not a pool policy.

```odin
pool.get(&p, &m, int(FlowId.Chunk), .Always)      // free list first, allocate if empty
pool.get(&p, &m, int(FlowId.Chunk), .Standalone)  // always allocate, ignore free list
pool.get(&p, &m, int(FlowId.Chunk), .Pool_Only)   // free list only, error if empty
```

| Mode | Behavior |
|---|---|
| `.Always` | take from free list if available, allocate if empty |
| `.Standalone` | always allocate, never touch free list |
| `.Pool_Only` | free list only, error if empty — never allocates |

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
mbox.init(&mb)
defer mbox.destroy(&mb)  // [itc: defer-destroy]

hooks := FLOW_HOOKS
hooks.ctx = &master
pool.init(&p, hooks = hooks, ids = {int(FlowId.Chunk), int(FlowId.Progress)})
defer pool.destroy(&p)
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

**Rule**: This is a foundational Odin pattern. In `odin-itc`, **never mark it with a tag** in the source code. It is documented here for reference only.

### Advice & Best Practices

1. **`defer-destroy`**:
   - Always use this for `Pool` and `Mailbox` instances owned by the current scope.
   - If the resource is part of a `Master` struct, the `master_dispose` proc handles the destroy calls.

2. **`defer-dispose`**:
   - Register immediately after `pool.get`. Never wait until after filling the item.
   - One dispose per one live `Maybe(^PolyNode)`. Never copy `m^` into a second `Maybe` — two owners, two potential frees, one corruption.

3. **Foundational `defer-unlock`**:
   - Never call `mbox.send` or `pool.get` (blocking) while holding a custom lock — deadlock risk.

### loop_mbox and nbio_mbox

- `loop_mbox` = loop + any wakeup (semaphore, custom, or anything)
- `nbio_mbox` = loop + nbio wakeup (a special case of `loop_mbox`)

`nbio_mbox.init_nbio_mbox` creates a `loop_mbox.Mbox` with an nbio-specific `WakeUper`.
All `loop_mbox` procs work on the returned pointer: `send`, `try_receive_batch`, `close`, `destroy`.

### Open item — backpressure

Backpressure should inform what gets allocated — chunks, jobs, etc.
When the system is under pressure, the `id` passed to `pool.get` may change
based on downstream capacity signals.
To be designed separately.

---

*There are several ways to skin a cat. These idioms are one way. Use what works for you.*
