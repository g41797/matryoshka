# Layer 4 — Meta — Infrastructure as Items — Quick Reference

> See previous layers for basics.
> Layer 1 — ownership.
> Layer 2 — movement.
> Layer 3 — reuse.

---

You get:

* Mailbox and Pool become items.
* Same ownership rules everywhere.
* Same transport for everything.

No new magic.
Just one model applied everywhere.

---

## Everything is a PolyNode

Mailbox is an item.
Pool is an item.

They embed `PolyNode` at offset 0.

```odin
_Mbox :: struct {
    using poly: PolyNode,
    alloc: mem.Allocator,
    // private fields
}

_Pool :: struct {
    using poly: PolyNode,
    alloc: mem.Allocator,
    // private fields
}
```

Public handle hides internals:

```odin
Mailbox :: distinct ^PolyNode
Pool    :: distinct ^PolyNode
```

You pass them as `^PolyNode`.
You cast only inside matryoshka.

---

## ID rules

One field.
Two meanings by convention.

| Value | Meaning        |
| ----- | -------------- |
| `0`   | invalid        |
| `> 0` | user data      |
| `< 0` | infrastructure |

Examples:

```odin
ID_MAILBOX = -1
ID_POOL    = -2
```

Do not mix ranges.

User owns positive ids.
Matryoshka uses negative ids.

---

## Ownership is unchanged

Same `Maybe(^PolyNode)`.

Same rules:

* `m^ != nil` → you own it
* `m^ == nil` → not yours

Mailbox follows the same rules.
Pool follows the same rules.

Nothing special here.

---

## Creation — simple only

Create directly.

```odin
m := mbox_new(alloc)
p := pool_new(alloc)
```

Each item stores its allocator inside.

No central manager.

No global factory.

---

## Dispose — self-destroy

```odin
matryoshka_dispose :: proc(m: ^Maybe(^PolyNode))
```

Algorithm:

* Check `m == nil` → return
* Check `m^ == nil` → return
* Read `m^.id`
* Cast to internal type
* Check state

| State  | Action                      |
| ------ | --------------------------- |
| closed | free using stored allocator |
| open   | fail                        |

After success:

* `m^ = nil`

You can only dispose closed items.


---

## Mailbox as item

You can send a Mailbox.

### Send side:

* Wrap mailbox pointer as `^PolyNode`
* Put into `Maybe`
* Call `mbox_send`

### Receive side:

* Receive into `Maybe`
* Cast to `Mailbox`
* Use normally

Mailbox is just another item.

---

## Pool as item

Same idea.

* Can be sent
* Can be owned
* Can be matryoshka_disposed

No special path.

---

## Self-send (advanced)

Mailbox can send itself.

Not what the doctor ordered...

But anyway

### Steps:

* Convert mailbox to `^PolyNode`
* Put into `Maybe`
* Send into same mailbox

Result:

* Sender loses ownership
* Receiver gains ownership

This is valid.

This is rare.

Use only if you know why.

---

## Pooling infrastructure

Don't allowed - you can not get/put Mailboxes/Pools.
Pool will acts as for "foreign" id

---

## What changed from Layer 3

* Before: only data is item
* Now: infrastructure is also item

What did not change:

* Ownership rules
* Mailbox behavior
* Pool behavior

---

## What you learned (Layer 4)

* One model is enough
* Everything can move
* Ownership stays simple
* Infrastructure is not special
* But infrastructure is not data

Keep that last line in mind.
