# What your doctor ordered

Follow this unless you have a reason not to.

---

## 1. Always check type before cast

```odin
if ptr.id != ChunkId {
    panic("wrong type")
}
````

No shortcuts.

---

## 2. Clear ownership immediately

After send:

```odin
if mbox_send(mb, &m) != .Ok {
    // m^ is unchanged — you still own it
    // free or retry
}
// On .Ok: m^ is already nil — ownership transferred
```

After put: `pool_put` sets `m^ = nil` on success — same rule applies.

Do not keep stale pointers.

---

## 3. Handle every error

```odin
if mbox_send(mb, &m) != .Ok {
    // you still own it
    free(ptr)
    m^ = nil
}
```

Never ignore return values.

---

## 4. One item → one path

Each item must end in exactly one place:

* sent
* returned to pool
* destroyed

No branching ownership.

---

## 5. Do not be clever with Maybe

Bad:

```odin
m2 = m
```

Good:

```odin
m2 = m
m^ = nil
```

Ownership must move, not copy.

---

## 6. Drain before shutdown

Before closing mailbox:

* stop producers
* receive all items
* destroy or return them

Never leave items inside.

---

## 7. Pool is not guaranteed reuse

Always assume:

* item may be destroyed on put
* item may be newly allocated on get

Write code that works in both cases.

---

## 8. Never touch after send

Bad:

```odin
mbox_send(mb, &m)
use(ptr) // BUG
```

After send → it is not yours.

---

## 9. Keep items simple

Prefer:

```odin
struct {
    using poly: PolyNode,
    data: T,
}
```

Avoid deep graphs and shared references.

---

## 10. When unsure — destroy

If ownership is unclear:

```odin
free(ptr)
m^ = nil
```

Leaking or double-using is worse.

---

## Final rule

If you cannot answer:

* who owns it
* where it goes
* who frees it

Stop and fix the code.

```
