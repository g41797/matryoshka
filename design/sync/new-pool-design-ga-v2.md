# odin-itc: Unified Pool Specification (v2.0)

## 1. Core Philosophy
The Pool is a **mechanism-only** MPMC container for `PolyNode` carriers. It provides thread-safe reuse while delegating all lifecycle decisions (allocation limits, backpressure, disposal, and node sanitization) to a user-provided `FlowPolicy`. Pool enforces strict ID validation — unknown id causes immediate panic.

## 2. Type Definitions

### 2.1 The Carrier (Intrusive Node)
Every type participating in the pool must embed `PolyNode` at offset 0.
```odin
PolyNode :: struct {
    using node: list.Node, // Intrusive link for MPMC free-lists
    id:   int,        // Type discriminator (stamped by factory)
}
```

### 2.2 Pool Get Modes
Controls how the pool behaves when the user requests a node.
```odin
Pool_Get_Mode :: enum {
    Recycle_Or_Alloc, // Default: Pop from free-list; if empty, call factory()
    Alloc_Only,       // Standalone: Bypass free-list; always call factory()
    Recycle_Only,     // Pool-Only: Pop from free-list; if empty, return false
}
```

### 2.3 FlowPolicy (The Brain)
```odin
FlowPolicy :: struct {
    ctx: rawptr, // User context (e.g., a Master struct or allocator)

    // Called when Get_Mode requires a new allocation.
    // in_pool_count: number of nodes of this 'id' currently in the free-list.
    factory: proc(ctx: rawptr, alloc: mem.Allocator, id: int, in_pool_count: int) -> (^PolyNode, bool),

    // Called BEFORE pool_get returns a recycled node to the user.
    // Use for sanitization/zeroing.
    on_get:  proc(ctx: rawptr, m: ^Maybe(^PolyNode)),

    // Called during pool_put, outside lock.
    // If hook sets m^ = nil → item consumed (e.g., disposed for backpressure).
    // If m^ != nil after hook → pool MUST add to free-list (invariant, not optional).
    on_put:  proc(ctx: rawptr, alloc: mem.Allocator, in_pool_count: int, m: ^Maybe(^PolyNode)),

    // Called for every node remaining in the pool during pool_destroy.
    dispose: proc(ctx: rawptr, alloc: mem.Allocator, m: ^Maybe(^PolyNode)),
}
```

---

## 3. API Reference

### `pool_init`
`pool_init(p: ^Pool, policy: FlowPolicy, ids: []int, alloc := context.allocator)`
Initializes MPMC headers and internal accounting.

`ids`: the complete set of valid item IDs this pool may hold. Must be non-empty. All IDs must be != 0. Passing an unknown ID to pool_put will panic.

### `pool_get`
`pool_get(p: ^Pool, id: int, mode: Pool_Get_Mode, out: ^Maybe(^PolyNode)) -> (ok: bool)`
* **Recycle_Or_Alloc**: Checks free-list first. Calls `on_get` on hit. Calls `factory` on miss.
* **Alloc_Only**: Always calls `factory`. Useful for initialization or bypassing "dirty" memory.
* **Recycle_Only**: Only checks free-list. Fails if empty (useful for fixed-size/no-alloc paths).

### `pool_put`
`pool_put(p: ^Pool, m: ^Maybe(^PolyNode))`
1. Validate: checks `m.?.id` against `pool.ids`. If not found → **PANIC**.
2. Retrieves `in_pool_count` for the node's `id`.
3. Calls `policy.on_put(...)` **outside of internal locks**.
4. If `m^` is still non-nil, pushes to MPMC free-list, increments count, and sets `m^ = nil`.

After pool_put returns, `m^` is **always nil**. This makes `defer pool_put` unconditionally safe.

### `pool_destroy`
`pool_destroy(p: ^Pool)`
1.  Locks all internal MPMC headers.
2.  Drains all free-lists into a local "death row" collection.
3.  Drops all internal locks.
4.  Calls `policy.dispose(...)` for every node on "death row."
5.  Clears accounting and frees internal headers.

---

## 4. Architectural Invariants

### I1: Ownership Finality (The `Maybe` Rule)
All APIs operate on `^Maybe(^PolyNode)`.
* **Input**: Passing a `Maybe` to an API implies a transfer candidate.
* **Output**: If the API sets `m^ = nil`, ownership is gone. If `m^ != nil`, the caller still owns the memory (e.g., if a send was rejected). pool_put always results in `m^ = nil`.

### I2: The Outside-Lock Rule (Deadlock Prevention)
The Pool is strictly prohibited from holding internal locks (mutexes/spinlocks) while executing any `FlowPolicy` hook.
* **Reason**: User hooks often access `ctx` which may contain application-level locks. Calling a hook inside a Pool lock creates a circular dependency risk.

### I3: Hygiene Guarantee
The `on_get` hook is the mandatory gatekeeper. No node may transition from "Recycled" to "In-Use" without passing through `on_get`. This ensures that data from a previous lifecycle cannot leak into a new task.

### I4: Accounting Symmetry
The Pool maintains an atomic `in_pool_count` per `id`.
* `factory` and `on_put` receive this count to make informed decisions about backpressure and memory growth.
* If `in_pool_count` exceeds a user-defined threshold in `on_put`, the hook should manually `dispose` and set `m^ = nil` to trim the pool.

### I5: Panic on Unknown ID
The pool refuses to accept any item whose id is not in the registered ids set.
This is an unrecoverable programming error — panic is the correct response.
Silent handling (returning the item to caller) masks bugs and creates undefined behavior.

---

## 5. Usage Idioms

### FlowId definition
```odin
FlowId :: enum int {
    Chunk    = 1,  // id must be != 0
    Progress = 2,
}
```

### Initialization (Seeding)
To pre-allocate a pool to avoid runtime latency:
```odin
pool_init(&my_pool, policy, {int(FlowId.Chunk), int(FlowId.Progress)})

for _ in 0..<100 {
    m: Maybe(^PolyNode)
    if pool_get(&my_pool, int(FlowId.Chunk), .Alloc_Only, &m) {
        pool_put(&my_pool, &m)
    }
}
```

### Safety Defer
The standard acquisition pattern:
```odin
m: Maybe(^PolyNode)
if pool_get(&pool, int(FlowId.Chunk), .Recycle_Or_Alloc, &m) {
    defer pool_put(&pool, &m) // Always safe: pool_put always sets m^ = nil (or panics on invalid id)
    // ... work ...
}
```

Why defer pool_put is safe:
- m^ = nil (transferred): pool_put is a no-op (m^ == nil on entry → nothing to do)
- m^ != nil (not transferred): pool_put recycles, or on_put hook disposes — either way m^ = nil
- invalid id: pool_put panics — programming error surfaces immediately
No silent "silently ignored" path exists.

### Backpressure Logic (Inside `on_put`)
```odin
on_put :: proc(ctx: rawptr, alloc: mem.Allocator, count: int, m: ^Maybe(^PolyNode)) {
    if m == nil || m^ == nil { return }
    if count > 512 {
        // Dispose — sets m^ = nil. Pool will not add to free-list.
        flow_dispose(ctx, alloc, m)
    }
    // If m^ is still non-nil here, pool MUST add it to the free-list.
}
```

***
