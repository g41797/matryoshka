# Matryoshka — first steps, mistakes, fixes

You start with something real.

You need to pass data.

You write types.

```odin
Event :: struct {
    using poly: item.PolyNode,
    code:    int,
    message: string,
}

Sensor :: struct {
    using poly: item.PolyNode,
    name:  string,
    value: f64,
}
````

You feel good.

Simple structs.
Nothing special.

---

You produce items.

```odin
ev := new(Event)
ev.poly.id = int(ItemId.Event)

list.push_back(&l, &ev.poly.node)
```

It works.

You add more.

---

You consume.

```odin
raw := list.pop_front(&l)
poly := (^item.PolyNode)(raw)

switch ItemId(poly.id) {
case .Event:
    ev := (^Event)(poly)
    free(ev)
}
```

Still works.

---

You forget to set id.

```odin
ev := new(Event)
// ev.poly.id is 0
list.push_back(&l, &ev.poly.node)
```

Later:

```odin
switch ItemId(poly.id) {
case:
    // unknown
}
```

You don’t know what this is.

You debug.

You see:

* id is zero

You fix it.

```odin
ev.poly.id = int(ItemId.Event)
```

You remember:

* zero is invalid
* always stamp id

---

You forget to free.

Code runs.

Memory grows.

You look again.

You see:

* every pop must end with free

You fix it.

---

You try to be careful.

You introduce `Maybe`.

```odin
m: Maybe(^item.PolyNode) = &ev.poly
```

Now ownership is explicit.

Feels better.

---

You push to list.

```odin
list.push_back(&l, &ev.poly.node)
```

You forget to drop ownership.

You still think you own it.

You touch it later.

Sometimes it works.
Sometimes it corrupts.

You realize:

* push transfers ownership

You fix it.

```odin
m = nil
```

You no longer own it.

---

You pop.

```odin
raw := list.pop_front(&l)
out: Maybe(^item.PolyNode) = (^item.PolyNode)(raw)
```

You unwrap wrong.

```odin
ptr := out.?   // panic later
```

It crashes.

You don’t see why.

You learn:

* single-value unwrap is dangerous

You fix it.

```odin
ptr, ok := out.?
if !ok {
    return false
}
```

Now safe.

---

You forget a path.

```odin
switch ItemId(ptr.id) {
case .Event:
    // free
case .Sensor:
    // forgot
}
```

Works for a while.

Then leaks.

You fix it.

You ensure:

* every branch ends

---

You want less boilerplate.

You write ctor/dtor.

```odin
ctor :: proc(id: int) -> Maybe(^item.PolyNode) {
    ev := new(Event)
    ev.poly.id = id
    return Maybe(^item.PolyNode)(&ev.poly)
}

dtor :: proc(m: ^Maybe(^item.PolyNode)) {
    ptr, ok := m.?
    if !ok { return }
    free((^Event)(ptr))
    m^ = nil
}
```

Feels cleaner.

---

You forget unknown id.

```odin
switch ItemId(ptr.id) {
case .Event:
    free((^Event)(ptr))
}
```

New type appears.

Crash.

Or leak.

You fix it.

```odin
case:
    free(ptr)
```

You learn:

* unknown must still be handled

---

You think:

“This is repetitive.”

You try to simplify.

You hide too much.

Later you debug.

You don’t know where ownership moved.

You roll back.

You keep things explicit.

---

You try to reuse items.

You don’t have pool yet.

You write small recycler.

You forget reset.

Old data leaks into new logic.

You fix it.

You reset fields.

---

You realize:

* allocation is easy
* reuse is tricky

---

You look at your first version.

You don’t like it.

You rewrite.

Cleaner.

Same rules.

---

You try to skip Maybe.

You pass raw pointers.

You lose track.

You double free.

Or leak.

You come back.

You keep Maybe.

---

You try to keep references after transfer.

You read after push.

You debug strange values.

You stop doing that.

---

You notice pattern:

* allocate
* stamp id
* transfer
* receive
* handle
* end

Always.

---

You stop guessing.

You start checking:

```odin
ptr, ok := m.?
```

Every time.

---

You stop writing “just in case”.

You write exact paths.

---

You understand:

* item lives in one place
* ownership is not shared
* nothing is implicit

---

You still make mistakes.

But now:

* they fail early
* they are visible
* they are local

---

You don’t keep your first code.

You keep:

* where you failed
* how you fixed it

---

Next step will come.

When something hurts.

Not before.

```
