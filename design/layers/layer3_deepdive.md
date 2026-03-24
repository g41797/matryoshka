# Layer 3 — Pool + Recycler — Deep Dive

> See [Quick Reference](layer3_quickref.md) for API signatures and contracts.
>
> **Prerequisite:** [Layer 1](layer1_quickref.md) + [Layer 2](layer2_quickref.md).

---

## Recycler — from Builder to hooks

You already have Builder from Layer 1.
Builder creates and destroys by id.

Recycler extends that idea.
Recycler adds:
- **Reuse** — reinitialize instead of destroy + create.
- **Policy** — decide whether to keep or drop.

The same creation and destruction logic from Builder lives in `on_get` and `on_put`.

---

## Hook examples

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

## Standalone Recycler use

Recycler without Pool is valid.
It is Builder with policy.
User calls `on_get` and `on_put` directly.
User decides keep or drop without pool storage.

---

## Why panic on unknown id?

A foreign id on `pool_put` is almost always a bug:
- wrong cast earlier
- wrong pool
- memory corruption
- use-after-free

Silent recycling would create silent starvation or use-after-free later.
A loud panic during development is far cheaper than hunting ghosts in production.

Zero is always invalid because it is the zero value of `int`.
An uninitialized `PolyNode` would have `id == 0`.
Panicking on zero catches missing initialization immediately.

---

## ID example

```odin
FlowId :: enum int {
    Chunk    = 1,  // must be != 0
    Progress = 2,
}

// Registration: populate hooks.ids before pool_init
append(&hooks.ids, int(FlowId.Chunk))
append(&hooks.ids, int(FlowId.Progress))
pool_init(&p, &hooks)
```

---

## Master with Pool — extending Layer 2's Master

In Layer 2, Master held Builder and mailbox references.
Now Master holds Pool and Recycler (PoolHooks) too.

Builder from Layer 1 becomes the basis for your hooks.
The same creation and destruction logic lives in `on_get` and `on_put`.

```odin
Master :: struct {
    pool:  Pool,
    hooks: PoolHooks,
    inbox: Mailbox,
    alloc: mem.Allocator,
    // ... other state ...
}

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.hooks = PoolHooks{
        ctx    = m,
        on_get = master_on_get,
        on_put = master_on_put,
    }
    append(&m.hooks.ids, int(FlowId.Chunk))
    append(&m.hooks.ids, int(FlowId.Progress))
    pool_init(&m.pool, &m.hooks)
    mbox_init(&m.inbox)
    return m
}

freeMaster :: proc(master: ^Master) {
    // 1. close pool — get back stored items
    nodes, _ := pool_close(&master.pool)

    // 2. drain and dispose all returned items
    // NOTE: dispose nodes before freeing other Master resources.
    for {
        raw := list.pop_front(&nodes)
        if raw == nil { break }
        // dispose node — master knows how
    }

    // 3. close and drain mailbox
    remaining := mbox_close(&master.inbox)
    // drain remaining...
    mbox_destroy(&master.inbox)

    // 4. delete ids dynamic array (user-owned)
    delete(master.hooks.ids)

    // 5. free Master last — save alloc first
    alloc := master.alloc
    free(master, alloc)
}
```

Pool borrows hooks — pointer, not copy.
`freeMaster` owns the full teardown.

---

## Pre-allocating (Seeding the Pool)

To avoid runtime latency, pre-allocate before starting Masters:

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

---

## Pool Get Modes — examples

Mode is a per-call parameter of `pool_get`.
Not a pool-wide setting.

```odin
// Normal operation — use stored item if available, create if not
pool_get(&master.pool, int(FlowId.Chunk), .Available_Or_New, &m)

// Force creation — use for seeding or when you want a guaranteed fresh item
pool_get(&master.pool, int(FlowId.Chunk), .New_Only, &m)

// Stored only — use in no-alloc paths
// Returns .Not_Available if no item stored — on_get not called
if pool_get(&master.pool, int(FlowId.Chunk), .Available_Only, &m) != .Ok {
    // no item stored — handle: skip, back off, or call pool_get_wait
}
```

---

## Patterns

### Builder to Pool — simplest upgrade from Layer 2

Replace Builder.ctor/dtor calls with pool_get/pool_put.
Same patterns, now with recycling.

Layer 2 sender:
```odin
m := b.ctor(b.alloc, int(FlowId.Chunk))
// fill
mbox_send(&mb, &m)
```

Layer 3 sender:
```odin
m: Maybe(^PolyNode)
defer pool_put(&p, &m)  // [itc: defer-put-early]
if pool_get(&p, int(FlowId.Chunk), .Available_Or_New, &m) != .Ok {
    return
}
// fill
mbox_send(&mb, &m)
// m^ is nil after send — defer pool_put is a no-op
```

---

### Backpressure

`on_put` checks `in_pool_count`.
Too many idle items → dispose.

```odin
// in master_on_put:
if in_pool_count > 400 {
    free((^Chunk)(node), master.alloc)
    m^ = nil  // dispose — pool will not store
}
```

Start simple.
Add limits when it hurts.

---

### Full lifecycle with mailbox

```
┌─────────────┐                        ┌─────────────┐
│Sender Master│                        │Recv Master  │
│             ├── pool                 │             ├── pool
│             ├── out  ════════════════►│             │
│             │                        │             ├── inbox ◄═
│             ├── inbox ◄═             │             │
└─────────────┘                        └─────────────┘
```

**Setup:**
```odin
FlowId :: enum int { Chunk = 1, Progress = 2 }

master := newMaster(context.allocator)
defer freeMaster(master)
```

**Sender Master:**
```odin
m: Maybe(^PolyNode)
defer pool_put(&master.pool, &m)  // [itc: defer-put-early]

if pool_get(&master.pool, int(FlowId.Chunk), .Available_Or_New, &m) != .Ok {
    return
}

// fill
ptr, ok := m.?
if !ok { return }
c := (^Chunk)(ptr)
c.len = fill(c.data[:])

// transfer
if mbox_send(&mb, &m) != .Ok {
    return  // send failed — defer pool_put recycles
}
// m^ is nil — transfer done — defer pool_put is a no-op
```

**Receiver Master:**
```odin
m: Maybe(^PolyNode)
defer pool_put(&master.pool, &m)  // safety net

if mbox_wait_receive(&mb, &m) != .Ok {
    return
}

ptr, ok := m.?
if !ok { return }

switch FlowId(ptr.id) {
case .Chunk:
    c := (^Chunk)(ptr)
    process_chunk(c)
    pool_put(&master.pool, &m)    // explicit return — defer is no-op

case .Progress:
    pr := (^Progress)(ptr)
    update_progress(pr)
    pool_put(&master.pool, &m)    // explicit return — defer is no-op
}
```

**Why both `defer pool_put` and per-case `pool_put`?**

- Per-case `pool_put` is the normal path — it sets `m^ = nil`.
- After that, the deferred `pool_put` fires and sees `m^ == nil` — becomes a no-op.
- The `defer` is a safety net for paths you did not anticipate.
- Belt and suspenders — intentional.

**Shutdown:**
```odin
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)
    m: Maybe(^PolyNode) = poly
    pool_put(&master.pool, &m)
    if m^ != nil {
        // pool was already closed — dispose manually
    }
}

freeMaster(master)
```

---

## What you can build with all three layers

- Compression pipeline — chunks flow from reader Master to worker Masters and back, recycled through Pool.
- Game engine — entities, bullets, particles allocated from Pool, dispatched across Masters, recycled on death.
- Network server — request buffers from Pool, dispatched to handler Masters, response buffers returned to Pool.
- Streaming processor — data flows through a chain of Masters, Pool absorbs allocation spikes.

Same vocabulary at every level: get → fill → send → receive → put back.
Only the hooks grow when you need control.
