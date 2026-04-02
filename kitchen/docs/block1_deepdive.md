# Doll 1 — PolyNode + MayItem — Deep Dive

> See [Quick Reference](block1_quickref.md) for API signatures and contracts.

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
    PolyNode.next ──────────────► next item in queue
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

- Services receive `^PolyNode` and store it — they don't know the concrete type.
- Only the code that created the item can safely cast `^PolyNode` back.
- One item, one holder at any moment.
- `^MayItem` makes this visible at every call site.

---

## Builder example: Event + Sensor

<!-- snippet: examples/block1/builder.odin:7-58 -->
```odin
Builder :: struct {
    alloc: mem.Allocator,
}

make_builder :: proc(alloc: mem.Allocator) -> Builder {
    return Builder{alloc = alloc}
}

ctor :: proc(b: ^Builder, id: int) -> MayItem {
    switch ItemId(id) {
    case .Event:
        ev := new(Event, b.alloc)
        if ev == nil {
            return nil
        }
        ev^.id = id
        return MayItem(&ev.poly)
    case .Sensor:
        s := new(Sensor, b.alloc)
        if s == nil {
            return nil
        }
        s^.id = id
        return MayItem(&s.poly)
    case:
        return nil
    }
}

dtor :: proc(b: ^Builder, m: ^MayItem) {
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
        if ptr.id == 999 { // EXIT_ID
            free(ptr, b.alloc)
        } else {
            panic("unknown id")
        }
    }
    m^ = nil
}
```

### What ctor does inside (so you don't have to)

This is the manual way — without Builder:

<!-- snippet: examples/block1/ownership.odin:12-22 -->
```odin
ev := new(Event, alloc)
// ...
ev^.id = int(ItemId.Event)
ev.code = 99
ev.message = "owned"
// ...
m: MayItem = &ev.poly
```

With Builder:

<!-- snippet: examples/block1/example_builder.odin:8-11 -->
```odin
b := make_builder(alloc)
// ...
m := ctor(&b, int(ItemId.Event))
```

Builder prevents the mistakes:

- You don't think about wrapping.
- You don't forget to set id.
- You don't accidentally `defer free` the original pointer.

### Standalone use

- Builder does not need a pool.
- Builder does not need a mailbox.
- Any code that creates and destroys polymorphic items can use Builder directly.

Matryoshka does not need Builder either.
Builder — everything described from here on — is your code.

Not forced. Not required.

Use it, change it, or write your own.

---

## Working with lists — produce and consume

### Produce

Allocate items.
Push to intrusive list:

<!-- snippet: examples/block1/produce_consume.odin:32-55 -->
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
    ev^.id = int(ItemId.Event)
    ev.code = i
    ev.message = "event"
    list.push_back(&l, &ev.poly.node)

    s := new(Sensor, alloc)
    if s == nil {
        return false
    }
    s^.id = int(ItemId.Sensor)
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

<!-- snippet: examples/block1/produce_consume.odin:58-81 -->
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
        fmt.printfln("unknown id: %d", poly.id)
        panic("unknown id")
    }
    processed += 1
}
```

### What you can build with Doll 1

- Intrusive lists in one thread — no extra allocations.
- Simple game entity systems — entities live in one list at a time.
- Single-threaded pipelines — read → process → write.
- Any system where ownership changes hands instead of data being shared.

No locks. No threads yet. Just clean ownership.

