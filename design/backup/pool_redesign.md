# Pool Redesign

---

## Author notes

---

## Reminder: WTH is ^Maybe(^PolyNode)

User has many types: Chunk, Progress, Token, ...

Service (queue, pool, mailbox) must work with all of them.

Service cannot import user types — that creates dependencies.

Solution: user embeds `PolyNode` in their struct. Service works with `^PolyNode` only.
No user types in service code. No dependencies.

```odin
PolyNode :: struct {
    using node: list.Node,  // the link — service chains items through this
    id:         int,        // which user type is behind this pointer — never 0
}
```

**node** — the link that lets the service chain items into a list.
User gets this for free by embedding `PolyNode`. No separate allocation needed.

**id** — user sets it once at creation. Service uses it to hand the item back.
User reads `id`, casts to the right type, done.

**Maybe(^PolyNode)** — who owns this item right now?
- `m^ != nil` — you own it. You must return, send, or free it.
- `m^ == nil` — you don't own it. Don't touch it.

No flags. No return codes. One look at `m^`.

**^Maybe** at APIs — service writes `nil` into your variable when it takes the item.

You check `m^` after the call. nil = gone. non-nil = still yours.

---

## THE FIRST RULE OF POOL

You don't know pool yet. You haven't seen the APIs. Read this first. Remember it.

Pool has many conditions, results, and rules.
That is not a bug — it is the point.
Pool tries to prevent almost every wrong combination before it becomes a silent failure.
Pool is strong. Pool saves lives. *(We are serious about the first part.)*

**The rule:** check the result of every API call.
The table below tells you what "ok" looks like for each one.
If it is not ok — fix the root cause. Do not retry the same mistake.

| API | Returns | "Ok" means |
|-----|---------|------------|
| `pool_init` | nothing | no panic — bad input panics immediately |
| `pool_get` | `Pool_Get_Result` | `.Ok` and `m^` is non-nil |
| `pool_get_wait` | `Pool_Get_Result` | `.Ok` and `m^` is non-nil |
| `pool_put` | nothing | `m^` is `nil` after the call — pool took it |
| `pool_close` | `(list.List, ^PoolHooks)` | always succeeds — drain the returned list |

For `pool_put`: if `m^` is still non-nil after the call, the pool is closed — you own the item, dispose manually.
For `pool_get` / `pool_get_wait`: any result other than `.Ok` has a specific meaning — see the result table below.

---

## PoolHooks

```odin
PoolHooks :: struct {
    ctx:    rawptr,
    ids:    [dynamic]int,   // user-owned; non-empty, all != 0; user deletes in freeMaster
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}
```

Two procs only. Both communicate through `m`.

Both procs are required.

`ctx` may be nil. Pool passes it as-is. Hook is responsible for handling nil `ctx` safely.

`ids` is a `[dynamic]int` owned by the user:
- Populate with `append` before calling `pool_init`
- Delete in `freeMaster` before `free(master, alloc)`.

---

## on_get contract

Pool calls `on_get` on every `pool_get` — except `Available_Only` when no item is stored.

Pool passes `m^` as-is. Hook decides what to do.

| Entry state | Meaning | Hook must |
|-------------|---------|-----------|
| `m^ == nil` | no item available | create a new item, set `node.id = id`, set `m^` |
| `m^ != nil` | recycled item | reinitialize for reuse |

`in_pool_count`: number of items with this `id` currently idle (stored) in the pool — not total live objects. Hook may use it to decide whether to create or not.

After `on_get`:

| Exit state | Meaning |
|------------|---------|
| `m^ != nil` | item ready — pool returns it to caller |
| `m^ == nil` | pool returns `.Not_Created` to caller |

`.Not_Created` is not always an error. Hook may return nil on purpose — for example, when it decides not to create more items.

`id` is always passed. Needed for creation. Can be read from `node.id` on recycle — but passing it avoids the cast.

---

## on_put contract

Pool calls `on_put` during `pool_put`, outside the lock.

`in_pool_count`: number of items with this `id` currently idle (stored) in the pool — not total live objects.

After `on_put`:

| Exit state | Meaning |
|------------|---------|
| `m^ == nil` | hook disposed it — pool discards |
| `m^ != nil` | pool stores it |

---

## Pool API

```odin
pool_init     :: proc(p: ^Pool, hooks: ^PoolHooks)
pool_close    :: proc(p: ^Pool) -> (list.List, ^PoolHooks)
pool_get      :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, m: ^Maybe(^PolyNode)) -> Pool_Get_Result
pool_put      :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
pool_get_wait :: proc(p: ^Pool, id: int, m: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

---

## Pool_Get_Mode

```odin
Pool_Get_Mode :: enum {
    Available_Or_New,  // existing item if available, otherwise create
    New_Only,          // always create
    Available_Only,    // existing item only — no creation, on_get not called if none stored
}
```

`pool_get_wait` with timeout = 0 is the same as `pool_get` with `Available_Only`.

---

## Pool_Get_Result

```odin
Pool_Get_Result :: enum {
    Ok,             // item returned in m^
    Not_Available,  // Available_Only: no item stored — on_get was not called
    Not_Created,    // on_get ran and returned nil — may be deliberate or failure
    Closed,         // pool is closed
    Already_In_Use, // m^ != nil on entry — caller holds an unreleased item
}
```

Caller always knows what to do:
- `.Ok` — use the item.
- `.Not_Available` — no item stored right now. Retry later or call `pool_get_wait`.
- `.Not_Created` — `on_get` ran but returned nil. May be policy or failure — caller decides.
- `.Closed` — pool is shut down. Do not retry.
- `.Already_In_Use` — `m^` was non-nil on entry. Release the current item first.

---

## pool_get / pool_get_wait — validation order

Both functions apply the same entry checks in this order:

| Priority | Check | Result |
|----------|-------|--------|
| 1 | `id == 0` | **panic** — zero id is always a programming error |
| 2 | `m^ != nil` | `.Already_In_Use` — caller holds an unreleased item |
| 3 | pool closed | `.Closed` |
| 4 | `id` not in registered set (open pool only) | **panic** — foreign id is a programming error |
| 5 | proceed with get logic | — |

---

## pool_put contract

- Foreign `id` (not in `ids[]`) → **panic** if open.


> **Implementation note:** Odin's `in` operator does not work on `[dynamic]int`. Use `slice.contains(hooks.ids[:], id)` or a linear scan for the id validation check.
- Closed pool + id != 0 → `m^` stays non-nil on return. Caller owns the item. Must dispose manually.
- Closed pool + id == 0 → **panic**
- Open pool → `on_put` decides: hook sets `m^=nil` (disposed) or leaves `m^!=nil` (stored).

`pool_put` has no return value. `m^` nil/non-nil after the call is the only signal.

---

## pool_close contract

```odin
nodes, h := pool_close(&p)
```

- Returns all items currently stored in the pool as `list.List`.
- Returns `^PoolHooks` — the pointer passed to `pool_init`.
- Post-close `pool_get`/`pool_put` are safe to call — they return `.Closed` or no-op.

Pool does not call `on_put` during close. User drains manually.

---

## Pool borrows hooks

`pool_init` takes `^PoolHooks`. Pool stores the pointer. User keeps the struct.

`Master` is always heap-allocated. `newMaster` and `freeMaster` are always written together — they are a pair. Both belong to the user's Master package.

```odin
Master :: struct {
    pool:  Pool,
    hooks: PoolHooks,
    alloc: mem.Allocator,  // allocator used to create Master — stored here for freeMaster
    ...
}

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.hooks = PoolHooks{
        ctx    = m,            // ctx points to heap Master
        on_get = master_on_get,
        on_put = master_on_put,
    }
    append(&m.hooks.ids, int(SomeId.A))  // populate ids before pool_init
    append(&m.hooks.ids, int(SomeId.B))
    pool_init(&m.pool, &m.hooks)
    return m
}

freeMaster :: proc(master: ^Master) {
    // 1. close pool — get back stored items
    nodes, _ := pool_close(&master.pool)

    // 2. drain and dispose all returned items
    // NOTE: dispose nodes before freeing other Master resources — dispose code may use Master fields.
    for {
        raw := list.pop_front(&nodes)
        if raw == nil { break }
        // dispose node — master knows how
    }

    // 3. clean up other Master resources
    // ...

    // 4. delete ids dynamic array (user-owned, populated before pool_init)
    delete(master.hooks.ids)

    // 5. free Master last — save alloc first, struct is gone after free
    alloc := master.alloc
    free(master, alloc)
}
```

`freeMaster` owns the full teardown. Nothing outside it should call `free` on `^Master` directly.

`ctx` is set at runtime. Do not set it in a compile-time constant.

---

## Hook skeletons

```odin
master_on_get :: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    master := (^Master)(ctx)
    if m^ == nil {
        // no item available — create new one using master.alloc
    } else {
        // recycled item — reinitialize using master fields
    }
}

master_on_put :: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    master := (^Master)(ctx)
    // use master fields to decide: store or dispose
    // set m^ = nil to dispose, leave non-nil to store
}
```

---

## Rules

- Hooks are called **outside the pool mutex** — guaranteed.
- Hooks may safely take their own locks without deadlock risk.
- Hooks must NOT call `pool_get` or `pool_put` — that would re-enter the pool and deadlock.
- Allocator stored in `ctx` must be thread-safe. Arena is single-threaded — wrong choice.
- `ctx` may be nil. Pool passes it as-is. Hook must handle nil `ctx` safely.
- `ctx` must outlive the pool. Do not tie `ctx` to a stack object or any resource freed before `pool_close`.

---

## Why still called Pool

"Cache", "Store", "Depot" lose the concurrency and reuse meaning.
Pool = items are obtained, used, and returned. That contract is unchanged.
The recycling policy is now pluggable, but it is still a pool.

---

## Open questions


### Pending

(none)
