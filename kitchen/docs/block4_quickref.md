# Doll 4 — Infrastructure as Items — Quick Reference

> **Prerequisite:** [Doll 1](block1_quickref.md) — ownership. [Doll 2](block2_quickref.md) — movement. [Doll 3](block3_quickref.md) — reuse.

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
Mailbox :: ^PolyNode
Pool    :: ^PolyNode
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

**Common behavior:** All Mailbox/Pool operations validate the handle's ID. If the ID does not match `ID_MAILBOX` or `ID_POOL` respectively, the operation will `panic`.

Do not mix ranges.

User owns positive ids.  
Matryoshka uses negative ids.

---

## Ownership is unchanged

Same `MayItem`.

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
matryoshka_dispose :: proc(m: ^MayItem)
```

How it works:

* Check `m == nil` → return
* Check `m^ == nil` → return
* Read `m^.id`
* Cast to internal type
* Check state

| State  | Action                      |
| ------ | --------------------------- |
| closed | free using stored allocator |
| open   | panic                       |

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

## Pooling Tools

You cannot do this.  
Do not try to get/put Mailboxes or Pools into a Pool.  
If the pool is open, it will treat them as a "foreign" id and panic.

