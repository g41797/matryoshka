# Doll 1 — PolyNode + MayItem — Quick Reference

> See [Deep Dive](block1_deepdive.md) for diagrams, examples, and extended explanations.

---

You get:

- Items that travel.
- Ownership that is visible.
- A factory that creates and destroys.

No threads. No queues. No pools.

Just clean ownership in one thread.

---

## PolyNode — the traveling struct

<!-- snippet: polynode.odin:6-42 -->
```odin
import list "core:container/intrusive/list"
// ...
PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int, // type tag, must be != 0
}
```

Every type that travels through matryoshka embeds `PolyNode` at **offset 0** via `using`:

<!-- snippet: examples/block1/types.odin:16-20 -->
```odin
Event :: struct {
    using poly: matryoshka.PolyNode, // offset 0 — required for safe cast
    code:       int,
    message:    string,
}
```

### Offset 0 rule

The cast `(^Event)(node)` is valid only if `PolyNode` is first.

- This is a convention.
- You follow it.
- Matryoshka has no compile-time check for this.

### Id rules

- `id` must be != 0.
- Zero is the zero value of `int`.
- An uninitialized `PolyNode` would have `id == 0`.

That is how you catch missing initialization — immediately.

Set `id` once at creation.

Use an enum:

<!-- snippet: examples/block1/types.odin:10-13 -->
```odin
ItemId :: enum int {
    Event  = 1,
    Sensor = 2,
}
```

---

## MayItem — who owns this item

```
m: MayItem

m^ == nil                       m^ != nil
┌───────────┐                   ┌───────────┐
│    nil    │  ← not yours      │   ptr ────┼──► [ PolyNode | your fields ]
└───────────┘                   └───────────┘
                                     you own this — must transfer, recycle, or dispose
```

**Core Ownership Rule:** `m^ == nil` means the item is not yours (e.g., empty or transferred). `m^ != nil` means you own the item and must transfer, recycle, or dispose of it.

### The Ownership Deal

All Matryoshka functions pass items using `^MayItem`.

```odin
m: MayItem

// m^ != nil  →  you own it. You must transfer, recycle, or dispose it.
// m^ == nil  →  not yours. Transfer complete, or nothing here.
// m == nil   →  nil handle. This is a bug. Function returns error.
```

**What you send:**

| `m` value | Meaning | What happens |
|-----------|---------|--------------|
| `m == nil` | nil handle | error |
| `m^ == nil` | you hold nothing | depends on function |
| `m^ != nil` | you own the item | proceed |

**What you get back:**

| Event | `m^` after return |
|-------|------------------|
| success (you gave it) | `nil` — you no longer hold it |
| success (you received it) | `non-nil` — you hold it now |
| failure | unchanged — you still hold it |

**Honest notes:**

- `Maybe` is a convention, not a guarantee.
- `MayItem` is a who-holds-this handle — one item, one holder.
- Copying without clearing the original is aliasing. Aliasing is forbidden.
- Nothing stops you from doing it — Odin has no borrow checker.
- Matryoshka makes who-holds-what visible.
- Following it is on you.

---

## Builder — create and destroy by id

Builder stores an allocator and provides `ctor` / `dtor` procs:

<!-- snippet: examples/block1/builder.odin:7-14 -->
```odin
Builder :: struct {
    alloc: mem.Allocator,
}

make_builder :: proc(alloc: mem.Allocator) -> Builder {
    return Builder{alloc = alloc}
}
```

`ctor(b: ^Builder, id: int) -> MayItem`:

- Allocates the correct type for `id` using `b.alloc`.
- Sets `poly.id`.
- Wraps the result in `MayItem`.
- Returns nil for unknown ids or allocation failure.

`dtor(b: ^Builder, m: ^MayItem)`:

- Frees the item using `b.alloc`.
- Sets `m^ = nil`.
- Safe to call with `m == nil` or `m^ == nil` — no-op.
- Panics on unknown id — a programming error.

