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

With `using poly: PolyNode` at offset 0, your struct *is* the node:
- No wrapper.
- No extra allocation.
- No extra indirection compared to non-intrusive.

---

## Services don't know your types

Matryoshka services
- receive `^PolyNode`
- store `^PolyNode`
- return `^PolyNode`.

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

This is _discipline_, not enforcement.

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
- The `^Maybe(^PolyNode)` rule (nil = you don't own it) is checked every time you pass an item.

---

## Builder example: Event + Sensor

<!-- snippet: examples/layer1/builder.odin:7-58 -->
```odin
Builder :: struct {
    alloc: mem.Allocator,
}

make_builder :: proc(alloc: mem.Allocator) -> Builder {
    return Builder{alloc = alloc}
}

ctor :: proc(b: ^Builder, id: int) -> Maybe(^PolyNode) {
    switch ItemId(id) {
    case .Event:
        ev := new(Event, b.alloc)
        if ev == nil {
            return nil
        }
        ev.poly.id = id
        return Maybe(^PolyNode)(&ev.poly)
    case .Sensor:
        s := new(Sensor, b.alloc)
        if s == nil {
            return nil
        }
        s.poly.id = id
        return Maybe(^PolyNode)(&s.poly)
    case:
        return nil
    }
}

dtor :: proc(b: ^Builder, m: ^Maybe(^PolyNode)) {
    if m == nil {
        return
    }
    ptr, ok := m^.?
    if !ok {
        return
    }
    switch ItemId(ptr.id) {
    case .Event:
        free((^Event)(ptr), b.alloc)
    case .Sensor:
        free((^Sensor)(ptr), b.alloc)
    case:
        panic("dtor: unknown id")
    }
    m^ = nil
}
    m^ = nil
}
```

### What ctor does inside (so you don't have to)

This is the manual way — without Builder:

<!-- snippet: examples/layer1/ownership.odin:12-22 -->
```odin
ev := new(Event, alloc)
// ...
ev.poly.id = int(ItemId.Event)
ev.code = 99
ev.message = "owned"
// ...
m: Maybe(^PolyNode) = &ev.poly
```

With Builder:

<!-- snippet: examples/layer1/example_builder.odin:8-11 -->
```odin
b := make_builder(alloc)
// ...
m := ctor(&b, int(ItemId.Event))
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

- Builder does not need a pool.
- Builder does not need a mailbox.
- Any code that creates and destroys polymorphic items can use Builder directly.

- Matryoshka does not need Builder either.
- Builder, Master — everything described from here on — is your code.
- Matryoshka gives you PolyNode, Mailbox, Pool.
The rest is friendly advice.

Not forced. Not required.

Use it, change it, or write your own.

One exception: Pool requires hooks (PoolHooks).

But even there, the simplest Builder — just ctor and dtor called from on_get/on_put — is enough.

---

## Working with lists — produce and consume

### Produce

Allocate items.
Push to intrusive list:

<!-- snippet: examples/layer1/produce_consume.odin:32-55 -->
```odin
// Drain on any exit path — no-op if list is already empty.
defer drain_list(&l, alloc)

// --- Produce: N pairs of (Event, Sensor) ---
N :: 3
for i in 0 ..< N {
    ev := new(Event, alloc)
    if ev == nil {
        return false
    }
    ev.poly.id = int(ItemId.Event)
    ev.code = i
    ev.message = "event"
    list.push_back(&l, &ev.poly.node)

    s := new(Sensor, alloc)
    if s == nil {
        return false
    }
    s.poly.id = int(ItemId.Sensor)
    s.name = "sensor"
    s.value = f64(i) * 1.5
    list.push_back(&l, &s.poly.node)
}
```

### Consume

- Pop from list.
- Dispatch on id.
- Process.
- Free:

<!-- snippet: examples/layer1/produce_consume.odin:58-81 -->
```odin
for {
    raw := list.pop_front(&l)
    if raw == nil {
        break
    }
    poly := (^PolyNode)(raw)

    switch ItemId(poly.id) {
    case .Event:
        ev := (^Event)(poly)
        fmt.printfln("Event:  code=%d  message=%s", ev.code, ev.message)
        free(ev, alloc)
    case .Sensor:
        s := (^Sensor)(poly)
        fmt.printfln("Sensor: name=%s  value=%f", s.name, s.value)
        free(s, alloc)
    case:
        panic("consume: unknown id")
    }
    processed += 1
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

**The Question:** I designed Matryoshka to use `^Maybe(^PolyNode)`, but why the extra layer? Can't I just use `^^PolyNode`? It's just two pointers. It's simpler. Why the `Maybe`?

**The Reality:** They are not the same. `^^PolyNode` is just a pointer to a pointer. It gives you two nil states:

- `m == nil` — the handle itself is nil.
- `*m == nil` — the inner pointer is null.

But it has no built-in "is this valid?" check.

`Maybe(T)` in Odin is a tagged union. It adds the `.?` operator and a clear meaning to the state:

| Expression | `^Maybe(^PolyNode)` | `^^PolyNode` |
|------------|---------------------|--------------|
| `m == nil` | nil handle — a bug | same |
| `m^ == nil` | you do NOT own it | same (but why? who knows.) |
| `m^ != nil` | you own it | same |
| ptr, ok := m^.? | safe unwrap | not possible |
| m^ = nil after send | ownership transferred | could mean anything |


The big deal is the transfer signal. With `^^PolyNode`, setting `*m = nil` just nulls a pointer. It doesn't tell the caller *why*. Did it transfer? Did it fail? Was it never there?

With `^Maybe(^PolyNode)`, `m^ = nil` is the rule:
- API sets it on success → "I took it, it's mine now."
- API leaves it on failure → "I didn't take it, still yours."
- You check it to know if you need to free it.

This makes `defer pool_put(&p, &m)` safe.
`pool_put` sees `m^ == nil` and does nothing.
With `^^PolyNode`, you'd have to track that by hand.

**Simpler view:**

```
m == nil      → nil handle        → bug, returns .Invalid
m^ == nil     → nothing inside    → you don't own it
m^ != nil     → item inside       → you own it
```

`^^PolyNode` only has two levels.
You lose the difference between "I gave it away" and "I never had one."

**The Result:** `Maybe` carries the ownership bit for free. And `m^.?` is the safe way to read it.

It puts the rules into the type:
- nil = not yours.
- non-nil = yours.
- `m^.?` = the safe way to check and grab the item in one go.

---

## The `.?` operator

**The Problem:** Two forms of `.?`. Which one is the right one?

**The Rule:** Always use the two-value form.

```odin
ptr, ok := m^.?
```

It's safe. No panics. `ok` is `false` if `m == nil`.

The single-value form is a trap:

```odin
ptr := m.?
```

It returns the value directly but **panics at runtime if m is nil.** In a multi-threaded app, this is a crash.

| Form | The Rule |
|------|----------|
| `ptr, ok := m.?` | use this — check and extract in one step |
| `ptr := m.?` | don't use this — it will crash your app |

---

> ***Author's note.*** *This dialogue never was. I never was fully sure about `^Maybe(^PolyNode)`. Still not sure. But it's right.*

---

## The manual way (with `^^PolyNode`)

> *I wanted to skip this. I was convinced to keep it. Here is why `Maybe` wins.*

If you use `^^PolyNode`, you have to add a flag by hand to get the same safety.

It would look like this:

```odin
// Manual equivalent of Maybe(^PolyNode)
Owned :: struct {
    ptr:   ^PolyNode,
    valid: bool,       // the flag Maybe gives you for free
}
```

Every single time you want to use it:

```odin
m: Owned
if m.valid {
    ptr := m.ptr
    // use ptr
}
```

And every time you hand it over:

```odin
m.ptr   = nil
m.valid = false
```

You'll forget. Or you'll read `m.ptr` while `m.valid` is false.
`Maybe` and the `.?` operator stop you from doing that.

**Summary:**

| | `^Maybe(^PolyNode)` | `^^PolyNode` + manual flag |
|---|---|---|
| ownership bit | built-in | you maintain it by hand |
| safe extract | `m^.?` — one step | `if valid { use ptr }` — error-prone |
| transfer | `m^ = nil` | two steps, easy to forget |
| compiler help | yes | no |
| memory | same cost | same cost, more noise |

---
|

---
