# Layer 1 — PolyNode + Maybe + Builder — Quick Reference

> See [Deep Dive](layer1_deepdive.md) for diagrams, examples, and extended explanations.

---

You get:
- Items that travel.
- Ownership that is visible.
- A factory that creates and destroys.

No threads. No queues. No pools.
Just clean ownership in one thread.

---

## PolyNode — the traveling struct

```odin
import list "core:container/intrusive/list"

PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int,       // must be != 0, describes the type of user data
}
```

Every type that travels through matryoshka embeds `PolyNode` at **offset 0** via `using`:

```odin
Event :: struct {
    using poly: PolyNode,   // offset 0 — required
    code:       int,
    message:    string,
}
```

### Offset 0 rule

The cast `(^Event)(node)` is valid only if `PolyNode` is first.
This is a convention.
You follow it.
Matryoshka has no compile-time check for this.

### Id rule

`id` must be != 0.
Zero is the zero value of `int`.
An uninitialized `PolyNode` would have `id == 0`.
That is how you catch missing initialization — immediately.

Set `id` once at creation.
Use an enum:

```odin
ItemId :: enum int {
    Event  = 1,  // must be != 0
    Sensor = 2,
}
```

---

## Maybe(^PolyNode) — who owns this item

```
m: Maybe(^PolyNode)

m^ == nil                       m^ != nil
┌───────────┐                   ┌───────────┐
│    nil    │  ← not yours      │   ptr ────┼──► [ PolyNode | your fields ]
└───────────┘                   └───────────┘
                                     you own this — must transfer, recycle, or dispose
```

Two states:
- `m^ == nil` → not yours.
- `m^ != nil` → yours. You must give it away or clean it up.

### Ownership contract

All matryoshka APIs pass items using `^Maybe(^PolyNode)`.

```odin
m: Maybe(^PolyNode)

// m^ != nil  →  you own it. You must transfer, recycle, or dispose it.
// m^ == nil  →  not yours. Transfer complete, or nothing here.
// m == nil   →  nil handle. Invalid. API returns error.
```

**Entry rules:**

| `m` value | Meaning | API response |
|-----------|---------|--------------|
| `m == nil` | nil handle | error |
| `m^ == nil` | caller holds nothing | depends on API |
| `m^ != nil` | caller owns item | proceed |

**Exit rules:**

| Event | `m^` after return |
|-------|------------------|
| success (send, put) | `nil` — ownership transferred |
| success (get, receive) | `non-nil` — you own it now |
| failure | unchanged — you still own it |

**Honest note:** `Maybe` is a convention, not a guarantee.
Nothing stops you from copying the pointer and using it after transfer.
Odin has no borrow checker.
Matryoshka makes ownership visible.
Following it is on you.

---

## Builder — create and destroy by id

Builder groups allocation and disposal behind two procs:

```odin
Builder :: struct {
    alloc: mem.Allocator,
    ctor:  proc(alloc: mem.Allocator, id: int) -> Maybe(^PolyNode),
    dtor:  proc(alloc: mem.Allocator, m: ^Maybe(^PolyNode)),
}
```

`ctor`:
- Allocates the correct type for `id`.
- Sets `node.id`.
- Wraps the result in `Maybe(^PolyNode)`.
- Returns nil for unknown ids.

`dtor`:
- Frees the item.
- Sets `m^ = nil`.
- Safe to call with `m == nil` or `m^ == nil` — no-op.

---

## What you learned (Layer 1)

- Item has one owner.
- Transfer is explicit.
- Every path must end.
- Builder handles creation and destruction.
- You write the policy.
- Builder is yours. Your code, your rules. Matryoshka does not need Builder. You do.
