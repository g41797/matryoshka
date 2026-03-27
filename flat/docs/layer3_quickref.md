# Layer 3 — Pool + Recycler — Quick Reference

> See [Deep Dive](layer3_deepdive.md) for hook examples, patterns, and extended explanations.
>
> **Prerequisite:** [Layer 1](layer1_quickref.md) + [Layer 2](layer2_quickref.md).

---

You get:
- Items that come back.
- Reuse without re-allocation.
- Policy hooks for flow control.

At some point allocations hurt.
Not always.
Only under pressure.

You add Pool.

First version is simple.
It works.

Then:
- too many items
- or not enough

You add limits.
You start to decide: keep or drop.

Reuse is not free.
It needs policy.

---

## THE FIRST RULE OF POOL

- Pool has many conditions, results, and rules.
- That is not a bug — it is the point.
- Pool tries to catch wrong combinations early — before they become silent failures.
- Pool is strong. Pool saves lives. *(We are serious about the first part.)*

**The rule:** check the result of every API call.

| API | Returns | "Ok" means |
|-----|---------|------------|
| `pool_init` | nothing | no panic — bad input panics immediately |
| `pool_get` | `Pool_Get_Result` | `.Ok` and `m^` is non-nil |
| `pool_get_wait` | `Pool_Get_Result` | `.Ok` and `m^` is non-nil |
| `pool_put` | nothing | `m^` is `nil` after the call — pool took it |
| `pool_close` | `(list.List, ^PoolHooks)` | always succeeds — drain the returned list |

For `pool_put`: if `m^` is still non-nil after the call, the pool is closed.
You own the item.
Dispose manually.

For `pool_get` / `pool_get_wait`: any result other than `.Ok` has a specific meaning.
See the result table below.

---

## Recycler — your hooks for the pool

Builder from Layer 1 creates and destroys by id.
Recycler extends that idea.
Recycler adds:
- **Reuse** — reinitialize instead of destroy + create.
- **Policy** — decide whether to keep or drop.
- **Counts** — `in_pool_count` tells how many items are idle.
- **Context** — `ctx` carries your state.
- **Setup** — `ids` declares which item types this pool handles.

```
Builder (Layer 1):   ctor + dtor + alloc
Recycler (Layer 3):  on_get + on_put + ctx + ids
```

### PoolHooks

```odin
PoolHooks :: struct {
    ctx:    rawptr,         // user context — carries master or any state
                            // may be nil — pool passes it as-is
    ids:    [dynamic]int,   // user-owned; non-empty, all > 0; user deletes in freeMaster
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}
```

Two procedures only.
Both communicate through `m`.
Both are required.

`ctx` may be nil.
Pool passes it as-is.
Hook must handle nil `ctx` safely.

`ids` is a `[dynamic]int` owned by the user:
- Populate with `append` before calling `pool_init`.
- Delete in `freeMaster` before `free(master, alloc)`.

**`ctx` is runtime** — cannot be set in a `::` compile-time constant.
Set it before calling `pool_init`.

### on_get rule

Pool calls `on_get` on every `pool_get`.
Exception: `Available_Only` when no item is stored.

Pool passes `m^` as-is.
Hook decides what to do.

| Entry state | Meaning | Hook must |
|-------------|---------|-----------|
| `m^ == nil` | no item available | create a new item, set `node.id = id`, set `m^` |
| `m^ != nil` | recycled item | reinitialize for reuse |

`in_pool_count`: number of items with this `id` currently idle in the pool.
Not total live objects.

After `on_get`:

| Exit state | Meaning |
|------------|---------|
| `m^ != nil` | item ready — pool returns `.Ok` to caller |
| `m^ == nil` | pool returns `.Not_Created` to caller |

`.Not_Created` is not always an error.
Hook may return nil on purpose.

### on_put rule

Called during `pool_put`, outside lock.

`in_pool_count`: current count of items with this id currently idle in the pool.

After `on_put`:

| Exit state | Meaning |
|------------|---------|
| `m^ == nil` | hook disposed it — pool discards |
| `m^ != nil` | pool stores it |

### Hook rules

- All hooks are called **outside the pool mutex** — guaranteed.
- Hooks may safely take their own locks without deadlock risk.
- Hooks must NOT call `pool_get` or `pool_put` — that re-enters the pool and deadlocks.
- Allocator stored in `ctx` must be thread-safe.
- `ctx` must outlive the pool.

---

## Pool API

Pool holds reusable items.
Works with `^PolyNode` only.
Does not know your types.
Pool is just storage.
All lifecycle decisions live in `PoolHooks`.

### Types

```odin
Pool :: distinct ^PolyNode

Pool_Get_Mode :: enum {
    Available_Or_New,  // existing item if available, otherwise create
    New_Only,          // always create
    Available_Only,    // existing item only — no creation, on_get not called if none stored
}

Pool_Get_Result :: enum {
    Ok,             // item returned in m^
    Not_Available,  // Available_Only: no item stored — on_get was not called
    Not_Created,    // on_get ran and returned nil — may be deliberate or failure
    Closed,         // pool is closed
    Already_In_Use, // m^ != nil on entry — caller holds an unreleased item
}
```

### New / Init / Close

```odin
pool_new           :: proc(alloc: mem.Allocator) -> Pool
pool_init          :: proc(p: Pool, hooks: ^PoolHooks)
pool_close         :: proc(p: Pool) -> (list.List, ^PoolHooks)
matryoshka_dispose :: proc(m: ^Maybe(^PolyNode))
```

`pool_init`:
- Takes `^PoolHooks`.
- Pool stores the pointer.
- User keeps the struct.
`pool_close` rule:

```odin
nodes, h := pool_close(p)
```

- Returns all items currently stored in the pool as `list.List`.
- Returns `^PoolHooks` — the pointer passed to `pool_init`.
- Pool zeros its internal hooks pointer on close.
- Post-close `pool_get`/`pool_put` return `.Closed` or no-op.
- Pool does not call `on_put` during close. User drains manually.

### get — acquire ownership

```odin
pool_get :: proc(p: Pool, id: int, mode: Pool_Get_Mode, m: ^Maybe(^PolyNode)) -> Pool_Get_Result
```


| Mode | Behavior |
|------|----------|
| `.Available_Or_New` | check free-list; call `on_get` on hit or miss |
| `.New_Only` | always call `on_get` with `m^==nil`; skip free-list |
| `.Available_Only` | free-list only; return `.Not_Available` if empty — `on_get` not called |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `m^` set to item |
| `.Not_Available` | `.Available_Only` and no item stored |
| `.Not_Created` | `on_get` ran and returned nil |
| `.Closed` | pool is closed |
| `.Already_In_Use` | `m^` was non-nil on entry — release current item first |

#### Validation order

Both `pool_get` and `pool_get_wait` apply the same entry checks:

| Priority | Check | Result |
|----------|-------|--------|
| 1 | `id == 0` | **panic** — zero id is always a programming error |
| 2 | `m^ != nil` | `.Already_In_Use` — caller holds an unreleased item |
| 3 | pool closed | `.Closed` |
| 4 | `id` not in registered set (open pool only) | **panic** — foreign id is a programming error |
| 5 | proceed with get logic | — |

### get_wait — block until item available

```odin
pool_get_wait :: proc(p: Pool, id: int, m: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

Equivalent to `pool_get(.Available_Only)` but with blocking.
Never calls `on_get` — only waits for an item to be stored.

`pool_get_wait` with timeout = 0 is the same as `pool_get` with `Available_Only`.

| `timeout` | Behavior |
|-----------|----------|
| `== 0` | non-blocking — returns `.Not_Available` immediately if no item stored |
| `< 0` | blocks forever — waits until an item is put back or pool is closed |
| `> 0` | blocks up to the duration — returns `.Not_Available` on expiry |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `m^` set to item |
| `.Not_Available` | no item stored (non-blocking or timeout expired) |
| `.Closed` | pool is closed, or closed while waiting |

If `pool_close` is called while a Master is waiting, all waiters wake and receive `.Closed`.

### put — return to pool

```odin
pool_put :: proc(p: Pool, m: ^Maybe(^PolyNode))
```

How it works:

1. Check `m.?.id`:
   - `id == 0` → **PANIC** (zero is always invalid)
   - `id not in ids[]` → **PANIC** (not registered — programming error)
     > **Implementation note:** Odin's `in` operator does not work on `[dynamic]int`. Use `slice.contains(hooks.ids[:], id)`.
2. Get `in_pool_count` for this id (under lock, then unlock)
3. Call `hooks.on_put(ctx, in_pool_count, m)` — **outside lock**
4. If `m^` is still non-nil → push to free-list, increment count, set `m^ = nil` (under lock)

Open pool → `on_put` decides: hook sets `m^=nil` (disposed) or leaves `m^!=nil` (stored).

> **Closed pool + valid id:** `pool_put` returns with `m^` still non-nil. Caller owns the item.
> Must dispose manually. Does not panic.

### defer pool_put — when is it safe?

`pool_put` with `m^ == nil` is always a no-op.
No id check. No panic.

This means `defer pool_put` can be placed immediately after `m: Maybe(^PolyNode)`, before `pool_get`:

```odin
m: Maybe(^PolyNode)
defer pool_put(p, &m)  // [itc: defer-put-early] — safe: pool_put is no-op when m^ == nil
if pool_get(p, id, .Available_Or_New, &m) != .Ok {
    return
}
// ... work ...
```

Three outcomes when `defer pool_put` fires:
- `m^ == nil` (pool_get failed, or item was transferred) → `pool_put` is a no-op.
- `m^ != nil` (item was not transferred) → `pool_put` recycles or `on_put` disposes.
- `m^ != nil` with unknown id or zero id → `pool_put` panics — programming error.

Safe for valid ids.
The panic is the correct behavior — it tells you exactly where the bug is.

> `[itc: defer-put-early]` — candidate for `design/sync/new-idioms.md`.

### put_all — return a chain

```odin
pool_put_all :: proc(p: Pool, m: ^Maybe(^PolyNode))
```

Walks the linked list starting at `m^`, calling `pool_put` on each node.
Panics on zero or unknown id in any node.

---

## ID Rules

- Every item id must be != 0. Zero is reserved/invalid.
- `pool_init` reads valid ids from `hooks.ids`.
- User populates with `append` before calling `pool_init`.
- `pool_put` panics on `id == 0` (open or closed).
- `pool_put` panics on unknown id only when the pool is **open**.
- Post-close the pool holds no hooks and cannot validate ids.
- Unknown id with closed pool leaves `m^` non-nil.
- `on_get` sets `node.id` at allocation time.
- Id values are user-defined integer constants — typically from an enum.

---

## What you learned (Layer 3)

- Reuse is not free — it needs policy.
- Pool is strong. Check every result.
- Your hooks grow when you need control.
- Pool code never changes. Only your hooks become smarter.
- You look back at your first code. You don't like it.
- You rewrite it. Nothing forces you to keep it.
- You keep only what you learned.
- Recycler is yours. Your hooks, your policy. Pool never changes. Your hooks grow.
