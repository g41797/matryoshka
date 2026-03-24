# Layer 1 — PolyNode + Maybe + Builder — Deep Dive

> See [Quick Reference](layer1_quickref.md) for API signatures and contracts.

---

## Intrusive vs non-intrusive

A **non-intrusive** queue allocates a wrapper node around your data:

```
[ queue node ] → [ your struct ]   ← two allocations, two indirections
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
No wrapper.
No extra allocation.
No extra indirection compared to non-intrusive.

---

## Services don't know your types

Matryoshka services receive `^PolyNode`, store `^PolyNode`, return `^PolyNode`.
They don't know what is inside.

All concrete type knowledge lives in user code.

`PolyNode.id` tells you the type. It makes the cast safe:
- Zero is always invalid.
- Unknown id is a programming error.
- Known id → you can cast. Correctness is on you.

---

## One place at a time

`list.Node` has exactly one `prev` and one `next`.
Linking an item into two lists at the same time corrupts both.
An item lives in exactly one place at a time.
The link structure makes correct use natural — one `prev`, one `next`, one place.
But nothing stops you from inserting the same node twice.
That would corrupt both lists.
This is discipline, not enforcement.

---

## Maybe — transfer and receive

### Transfer

**Before transfer:**
```
┌───────────┐
│   ptr ────┼──► [item]
└───────────┘
  m^ != nil (yours)
```

**After transfer:**
```
┌───────────┐
│    nil    │   [item] → now held by someone else
└───────────┘
  m^ == nil (not yours anymore)
```

### Receive

**Before receive:**
```
┌───────────┐
│    nil    │
└───────────┘
  m^ == nil (empty)
```

**After receive:**
```
┌───────────┐
│   ptr ────┼──► [item]   ← handed to you
└───────────┘
  m^ != nil (yours now)
```

### Two levels

- **`list.Node`** — the link. One `prev`, one `next`. If you put a node in two lists, both break.
- **`Maybe`** — the ownership flag. `nil` = not yours. Non-nil = yours.

### Why ownership matters

- Mailbox and Pool are opaque — they cannot track what type they hold.
- Master is the only actor that can safely cast `^PolyNode` back to a concrete type.
- Only one Master should hold a given item at any moment.
- The `^Maybe(^PolyNode)` contract (nil = you don't own it) is checked at every API boundary.

---

## Builder example: Event + Sensor

```odin
item_ctor :: proc(alloc: mem.Allocator, id: int) -> Maybe(^PolyNode) {
    switch ItemId(id) {
    case .Event:
        ev := new(Event, alloc)
        ev.poly.id = id
        return Maybe(^PolyNode)(&ev.poly)
    case .Sensor:
        s := new(Sensor, alloc)
        s.poly.id = id
        return Maybe(^PolyNode)(&s.poly)
    case:
        return nil
    }
}

item_dtor :: proc(alloc: mem.Allocator, m: ^Maybe(^PolyNode)) {
    if m == nil {
        return
    }
    ptr, ok := m.?
    if !ok {
        return
    }
    switch ItemId(ptr.id) {
    case .Event:
        free((^Event)(ptr), alloc)
    case .Sensor:
        free((^Sensor)(ptr), alloc)
    case:
        free(ptr, alloc)
    }
    m^ = nil
}

make_builder :: proc(alloc: mem.Allocator) -> Builder {
    return Builder{
        alloc = alloc,
        ctor  = item_ctor,
        dtor  = item_dtor,
    }
}
```

### What ctor does inside (so you don't have to)

This is the manual way — without Builder:

```odin
ev := new(Event)
ev.poly.id = int(ItemId.Event)
ev.code    = 99
m: Maybe(^PolyNode) = &ev.poly
// Maybe is the sole owner now. Do NOT defer free(ev).
```

With Builder:
```odin
m := b.ctor(b.alloc, int(ItemId.Event))
// done. Builder allocated, set id, wrapped in Maybe.
```

Builder prevents the mistakes.
You don't think about wrapping.
You don't forget to set id.
You don't accidentally `defer free` the original pointer.

> **Note for hook implementors.**
> In full matryoshka with Pool, this pattern appears only inside `on_get`.
> User code calls `pool_get` — never `new` directly.
> `on_get` allocates (when `m^==nil`), sets id, and sets `m^`; the pool returns it to the caller.
> Outside of hooks, this is not a user-code pattern.

### Standalone use

Builder does not need a pool.
Builder does not need a mailbox.
Any code that creates and destroys polymorphic items can use Builder directly.

Matryoshka does not need Builder either.
Builder, Master — everything described from here on — is your code.
Matryoshka gives you PolyNode, Maybe, Mailbox, Pool.
The rest is friendly advice.
Not forced. Not required.
Use it, change it, or write your own.

One exception: Pool requires hooks (PoolHooks).
But even there, the simplest Builder — just ctor and dtor wrapped into on_get/on_put — is enough.

---

## Working with lists — produce and consume

### Produce

Allocate items via Builder.
Push to intrusive list:

```odin
l: list.List
b := make_builder(context.allocator)

for i in 0..<3 {
    m := b.ctor(b.alloc, int(ItemId.Event))
    ptr, ok := m.?
    if !ok { continue }
    ev := (^Event)(ptr)
    ev.code = i
    ev.message = "event"
    list.push_back(&l, &ptr.node)
}
```

### Consume

Pop from list.
Dispatch on id.
Process.
Destroy via Builder:

```odin
for {
    raw := list.pop_front(&l)
    if raw == nil { break }
    poly := (^PolyNode)(raw)

    switch ItemId(poly.id) {
    case .Event:
        ev := (^Event)(poly)
        // process event
        m: Maybe(^PolyNode) = poly
        b.dtor(b.alloc, &m)
    case .Sensor:
        s := (^Sensor)(poly)
        // process sensor
        m: Maybe(^PolyNode) = poly
        b.dtor(b.alloc, &m)
    case:
        // unknown id — still clean up
        m: Maybe(^PolyNode) = poly
        b.dtor(b.alloc, &m)
    }
}
```

### What you can build with Layer 1

- Intrusive lists in one thread — no extra allocations.
- Simple game entity systems — entities live in one list at a time.
- Single-threaded pipelines — read → process → write.
- Any system where ownership changes hands instead of data being shared.

No locks. No threads yet. Just clean ownership.

---

# Addendums

These are real conversations between the Author and AI.

---

## `^Maybe(^PolyNode)` vs `^^PolyNode`

**Author:** I designed how to use `^Maybe(^PolyNode)` for matryoshka, but I still don't fully understand why it has to be this way. Can't I just use `^^PolyNode`? It's simpler. Two pointers. Why do I need `Maybe` at all? Explain it to me.

**AI:** They are not equivalent. `^^PolyNode` is a pointer to a pointer. It gives you two nil states:

- `m == nil` — the handle itself is nil.
- `*m == nil` — the inner pointer is null.

But it has no unwrap operator. No "valid or not" semantics built into the type.

`Maybe(T)` in Odin is a tagged union: `union { T, nil }`. It adds the `.?` operator and one extra semantic state:

| Expression | `^Maybe(^PolyNode)` | `^^PolyNode` |
|------------|---------------------|--------------|
| `m == nil` | nil handle — programming error | same |
| `m^ == nil` | you do NOT own the item | same (but ambiguous — was it transferred? freed? never set?) |
| `m^ != nil` | you own it | same |
| `ptr, ok := m.?` | safe unwrap | not available |
| `m^ = nil` after send | unambiguous: ownership transferred | ambiguous: could mean anything |

The critical difference is the transfer signal. With `^^PolyNode`, setting `*m = nil` just means the inner pointer is null. Nothing more. It cannot tell the caller whether the item was transferred, freed, never allocated, or hit an error condition.

With `^Maybe(^PolyNode)`, `m^ = nil` is the ownership transfer rule:
- API sets it on success → "I took it, you no longer own it."
- API leaves it on failure → "Still yours, I didn't take it."
- Caller checks it to know whether to free on exit.

This is why `defer pool_put(&p, &m)` works:
`pool_put` checks `m^ == nil` → no-op if already transferred.
With `^^PolyNode`, you cannot make that check reliably.

**Author:** OK, too much. What about three nil levels?

**AI:** Right, simpler:

```
m == nil      → nil handle        → programming error, return .Invalid
m^ == nil     → inner is nil      → don't own it (transferred or nothing)
m^ != nil     → inner is non-nil  → you own it
```

`^^PolyNode` only has two of these levels.
The difference between "transferred" and "never had it" disappears.

**Author:** So Maybe carries the ownership bit for free. And `.?` is the safe way to read it.

**AI:** Exactly. `Maybe` puts the ownership contract into the type:
- nil inner = not yours.
- non-nil inner = yours.
- `.?` = safe check-and-extract in one step.

`^^PolyNode` is just a raw double pointer with no ownership meaning.

**Author:** Keep `^Maybe(^PolyNode)`.

---

## The `.?` unwrap operator

**Author:** I keep seeing `.?` in the code. Two forms. Which one do I use?

**AI:** `Maybe(T)` in Odin is a tagged union: `union { T, nil }`. `.?` is the unwrap operator.

Two-value form — **use this**:

```odin
ptr, ok := m.?
```

Safe. No panic. `ok` is `false` if `m == nil`. `ptr` is only valid when `ok` is `true`.

Single-value form — **big no-no**:

```odin
ptr := m.?
```

Returns the inner value directly. **Panics at runtime if `m == nil`.** In concurrent code a panic here means a crash with no recovery.

**Author:** So always two-value form. Got it.

**AI:** Yes. Here's the summary:

| Form | Rule |
|------|------|
| `ptr, ok := m.?` | always use this — check and extract in one step |
| `ptr := m.?` | big no-no — panics if nil |
| `^^PolyNode` | neither form available — raw dereference only |

**Author:** Do not use the single-value form in matryoshka code.

---

> ***Author's note.*** *This dialog never was. I never was fully sure about `^Maybe(^PolyNode)`. Still not sure. But it's right.*

---

## How to implement `Maybe` "magic" using `^^PolyNode`

> *Author wanted to skip this section. AI insisted. Author agreed.*

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

---
