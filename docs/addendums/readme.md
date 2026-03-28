
# Matryoshka — Inter-Thread Communication for Odin

A low-level library for moving data between threads.

No shared mutable data.
Explicit ownership.
Intrusive data structures.

---

## What this library does

You pass items between threads.

You do not share them.
You do not lock them.
You transfer ownership.

---

## Core model

Everything is built on three concepts:

### 1. Intrusive item

Every item embeds a base node at offset 0.

```odin
PolyNode :: struct {
    using node: list.Node,
    id: int,
}
````

Your types embed it:

```odin
Chunk :: struct {
    using poly: PolyNode,
    value: int,
}
```

---

### 2. Ownership (`MayItem`)

Ownership is explicit.

```odin
m: MayItem
```

Rules:

* `m^ != nil` → you own the item
* `m^ == nil` → you do not own anything

You must always do one of:

* send it
* return it to pool
* destroy it

No implicit cleanup.

---

### 3. Movement (Mailbox)

Mailbox transfers ownership between threads.

* `mbox_send` → ownership leaves sender
* `mbox_wait_receive` → ownership goes to receiver

Items are not copied.
Pointers are moved.

---

## Ownership rules (important)

### Send

| result | ownership |
| ------ | --------- |
| Ok     | mailbox   |
| error  | sender    |

### Receive

| result | ownership |
| ------ | --------- |
| Ok     | receiver  |
| no msg | unchanged |

---

## Pool (reuse)

Pool allows reuse of items.

User provides hooks:

```text
on_get:
- if empty → create
- if reused → reset

on_put:
- set m^ = nil → destroy
- keep m^ → reuse
```

Important:

* Pool controls the flow — it decides when hooks are called (and when not to).
* When hooks are called, hooks decide the item's fate.
* `on_put`: hook keeps (`m^ != nil`) or destroys (`m^ = nil`) — hook's call.

---

## Infrastructure lifecycle (IMPORTANT)

Mailbox and Pool are **owned objects**.

They follow ownership rules, but have **extra lifecycle constraints**.

---

### Mailbox lifecycle

You must:

1. stop producers
2. drain or handle remaining items
3. call `mbox_close`
4. dispose mailbox

❗ Undefined behavior if items remain and you dispose blindly

You must decide:

* drain and destroy
* drain and return to pool
* reject new items

---

### Pool lifecycle

Pool also owns items internally.

You must:

1. stop all users of the pool
2. ensure no items are in-flight
3. dispose the pool

On dispose:

* all stored items must be destroyed
* no items may escape

❗ Pool must not outlive items in use
❗ Items must not reference a dead pool

---

### Shared rule

For both Mailbox and Pool:

* they are not regular data
* they must not be pooled
* they must not be sent unless you fully control lifecycle

---

## Non-obvious rules (read this)

### Intrusive node

* `PolyNode` must be first field
* item must be in only one container at a time

---

### Maybe

* represents unique ownership
* do not copy without transfer
* do not alias

---

### Casting

Always check `id` before casting.

```odin
if ptr.id == ChunkId {
    chunk := (^Chunk)(ptr)
}
```

---

### Failure handling

You must handle ownership on every error path.

Example:

```odin
if mbox_send(...) != .Ok {
    // you still own the item
}
```

---

## Minimal example

```odin
c := new(Chunk)
c.id = 1
c.value = 42

m: MayItem = (^PolyNode)(c)

// give away
list.push_back(&q, &m.node)
m^ = nil

// take back
raw := list.pop_front(&q)
m^ = (^PolyNode)(raw)

chunk := (^Chunk)(m^)

free(chunk)
m^ = nil
```

---

## What this library is NOT

* not high-level
* not memory-safe
* not type-safe
* not beginner-friendly

It gives control, not protection.

---

## When to use

Use if you need:

* strict ownership control
* no shared mutable data
* custom memory management
* predictable threading behavior

Do not use if you want:

* automatic safety
* simple abstractions
* managed lifecycle

---

## Mental model

Instead of:

* who locks
* who waits
* who frees

Think:

* who owns this now
* where does it go next
* who releases it

---

## Summary

* ownership is explicit
* data is not shared
* movement replaces synchronization

Everything else is built on top.

```
