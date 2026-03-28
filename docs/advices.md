# matryoshka — Advices

These are not rules.
They are patterns that worked.
Take what helps, ignore the rest.
But remember - _"advices are written in blood”_

---

## Explicit allocators

All functions that allocate or free memory must receive the allocator explicitly.
Do not rely on `context.allocator`.

- `new(T, alloc)` — not `new(T)`.
- `free(ptr, alloc)` — not `free(ptr)`.
- `make([]T, n, alloc)` — not `make([]T, n)`.
- If a struct stores an allocator as a field, all internal calls use the stored one.

Why:
- `context.allocator` can be changed at any point up the call stack.
- A function that uses `context.allocator` may silently allocate from a different allocator than the one that will be used to free.
- Explicit allocator makes the allocation source visible at every call site.

This is the author's mindset about allocation safety.
When the default allocator may be changed, an explicit one should be used.

### Builder pattern

Builder stores the allocator.
All procs that allocate or free use the stored allocator.

<!-- snippet: examples/layer1/builder.odin:7-14 -->
```odin
Builder :: struct {
    alloc: mem.Allocator,
}

make_builder :: proc(alloc: mem.Allocator) -> Builder {
    return Builder{alloc = alloc}
}
```

Usage:

<!-- snippet: examples/layer1/example_builder.odin:8-11 -->
```odin
b := make_builder(alloc)
m := ctor(&b, int(ItemId.Event))
```

### Example procs

Every example proc takes `alloc: mem.Allocator` as parameter.
Tests pass `context.allocator`.

---

## Defer cleanup

Every allocated resource must be released — on success and on error.
Use `defer` for cleanup that must happen on all exit paths.

### Collection cleanup

When building a collection in a loop, set up a defer drain at the start.
If an allocation fails mid-loop, the defer cleans up everything already added.

<!-- snippet: examples/layer1/produce_consume.odin:32-33 -->
```odin
// Drain on any exit path — no-op if list is already empty.
defer drain_list(&l, alloc)
```

The drain helper pops and frees all items by id:

<!-- snippet: examples/layer1/produce_consume.odin:8-23 -->
```odin
drain_list :: proc(l: ^list.List, alloc: mem.Allocator) {
    for {
        raw := list.pop_front(l)
        if raw == nil {
            break
        }
        poly := (^PolyNode)(raw)
        switch ItemId(poly.id) {
        case .Event:
            free((^Event)(poly), alloc)
        case .Sensor:
            free((^Sensor)(poly), alloc)
        case:
            panic("drain: unknown id")
        }
    }
}
```

### After transfer

After a successful transfer to an **open** pool or mailbox, `m^` is nil.
A deferred cleanup that checks `m^` becomes a no-op — no double free.
Transfer to a closed pool or mailbox leaves `m^` non-nil — you still own it.

---

## Unknown id

Allocation and deallocation handle unknown ids differently.

### Allocation (ctor, new, make)

Return `nil` for unknown id.
Unknown id at allocation time is a caller mistake — maybe a wrong constant, maybe a missing enum case.
Returning nil lets the caller handle it the same way as allocation failure.

### Deallocation (dtor, free, drain)

Panic on unknown id.
If you are freeing an item with an unknown id, the item should never have existed.
This is a programming error — not a runtime condition.
Panic immediately. Do not silently free. Do not return an error.

---

# Addendums

## Rules

You are not going to memorize this table.
But when something breaks, you will come back here.

| # | Rule | What breaks |
|---|------|-------------|
| R1 | `m^` is the ownership bit. Non-nil = you own it. | Double-free or leak. |
| R2 | All callbacks called outside pool mutex. | Guaranteed by pool. User may hold their own locks inside callbacks. |
| R3 | `on_get` is called on every `pool_get` except `Available_Only` — `on_get` is never called for `Available_Only`. | Hook handles both create (`m^==nil`) and reinitialize (`m^!=nil`). |
| R4 | Pool maintains per-id `in_pool_count`. Passed to `on_get` and `on_put`. | Enables flow control. |
| R5 | `id == 0` on `pool_put` or `mbox_send` → immediate panic or `.Invalid`. | Programming errors surface immediately. |
| R6 | Unknown id on `pool_put` → **panic** if pool is open. Closed pool: `m^` stays non-nil — caller owns the item. | Open pool: unknown id is a programming error — panic surfaces it immediately. Closed pool: pool can no longer manage items, so ownership is returned to caller for clean shutdown. |
| R7 | `on_put`: if `m^ != nil` after hook → pool stores it. If `m^ == nil` → pool discards. | Hook sets `m^ = nil` to dispose. |
| R8 | Always use `ptr, ok := m.?` to read the inner value of `MayItem`. Never use the single-value form `ptr := m.?`. | Single-value form panics if nil. |
| R9 | `ctx` must outlive the pool. Do not tie `ctx` to a stack object or any resource freed before `pool_close`. | Hook called after `ctx` freed → use-after-free. |

---
