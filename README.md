![](_logo/DancingMatryoshka.png)

# Matryoshka — Layered Inter-Thread Communication

One layer at a time.
Stop when you have enough.

[![CI](https://github.com/g41797/matryoshka/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/matryoshka/actions/workflows/ci.yml)

---

## What changes in your head

You write multi-threaded code.
Data moves between threads.

Before Matryoshka you think:
- who locked what
- who waits
- who frees

With Matryoshka you think:
- where does this go next
- who owns it right now
- when do I return it

That is the only real change.

---

## What Matryoshka really is

- Matryoshka is a set of Russian dolls.
- Each doll works by itself.
- You open only what you need.
- You stop when you have enough.

No hidden system.
No second model.

---

## The real rule (read this once)

Everything follows one rule:

- Items are `PolyNode`
- Ownership is `Maybe(^PolyNode)`
- Movement is Mailbox
- Reuse is Pool

Later you notice:

- Mailbox is also an item
- Pool is also an item

Same rules.
Nothing special.

---

## The smallest possible example

This is the whole system without threads or pools.
Everything else is just scaling this idea.

```odin
import list "core:container/intrusive/list"
import "core:fmt"

PolyNode :: struct {
    using node: list.Node,
    id: int,
}

Chunk :: struct {
    using poly: PolyNode,
    value: int,
}

main :: proc() {
    q: list.List

    c := new(Chunk)
    c.id = 1
    c.value = 42

    m: Maybe(^PolyNode) = (^PolyNode)(c)

    list.push_back(&q, &m.node)
    m^ = nil

    raw := list.pop_front(&q)
    if raw == nil { return }

    m^ = (^PolyNode)(raw)

    chunk := (^Chunk)(m^)
    fmt.println(chunk.value)

    free(chunk)
    m^ = nil
}
````

---

## The same idea with threads (Mailbox)

Now replace the list with a Mailbox.
Ownership rules stay the same.

```odin
import "core:thread"
import "core:fmt"

worker :: proc(arg: rawptr) {
    mb := (Mailbox)(arg)

    m: Maybe(^PolyNode)

    if mbox_wait_receive(mb, &m) != .Ok {
        return
    }

    ptr, ok := m.?
    if !ok { return }

    chunk := (^Chunk)(ptr)
    fmt.println(chunk.value)

    free(chunk)
    m^ = nil
}

main :: proc() {
    mb := mbox_new(context.allocator)
    defer {
        m: Maybe(^PolyNode) = (^PolyNode)(mb)
        mbox_close(mb)
        matryoshka_dispose(&m)
    }

    t: thread.Thread
    thread.create(&t, worker, mb)

    c := new(Chunk)
    c.id = 1
    c.value = 42

    m: Maybe(^PolyNode) = (^PolyNode)(c)

    if mbox_send(mb, &m) != .Ok {
        free(c)
        return
    }

    thread.join(t)
}
```

---

## Your four dolls

| Doll | What you get              | What you still do not need |
| ---- | ------------------------- | -------------------------- |
| 1    | PolyNode + Maybe          | everything else            |
| 2    | + Mailbox (movement)      | pool                       |
| 3    | + Pool (reuse)            | infrastructure as items    |
| 4    | + Infrastructure as items | — full system              |

**Rule:** open the next doll only when you feel pain.

---

## Doll 1 — PolyNode + Maybe

One struct.
One rule.

```odin
PolyNode :: struct {
    using node: list.Node,
    id:         int,
}
```

Every item embeds it first.

```odin
Chunk :: struct {
    using poly: PolyNode,
    data: [4096]byte,
}
```

Ownership:

```odin
m: Maybe(^PolyNode)
```

* `m^ == nil` → not yours
* `m^ != nil` → yours

You must:

* give it away
* or clean it up

---

## Doll 2 — Mailbox

Items move between threads.

* `mbox_send` → ownership leaves you
* `mbox_wait_receive` → ownership comes to you

You do not share memory.
You move ownership.

---

## Doll 3 — Pool

Now you reuse items.

```odin
on_get:
- m^ == nil → create
- m^ != nil → reset

on_put:
- set m^ = nil → destroy
- leave m^ → keep
```

Start simple.
Add limits later.

---

## Doll 4 — Infrastructure as items

Mailbox is an item.
Pool is an item.

* you can send them
* you can receive them
* you own them or not

Same rules.

---

## One vocabulary everywhere

* get
* fill
* send
* receive
* put back

---

## Practical notes

* Use positive ids for your data
* System uses negative ids
* Close Mailbox before dispose
* Do not pool Mailbox or Pool

---

## Takeaway

Matryoshka is not a big library.

It is one idea:

* ownership is visible
* data moves
* nothing is shared

If your code reads like this:

* I get it
* I fill it
* I send it
* I receive it
* I return it

then it works.

---

## Credits

Not serious. But not random either.

- "*?*M" — opened my eyes. Predecessor of `Maybe(^PolyNode)`.
- [mailbox](https://github.com/g41797/mailbox) — this project started as a port of mailbox to Odin.
- [tofu](https://github.com/g41797/tofu) — where these ideas began.

---

Don't shoot the
AI image generator; he's doing his best! 🤖🎨
