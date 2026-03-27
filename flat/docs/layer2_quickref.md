# Layer 2 — Mailbox + Master — Quick Reference

> See [Deep Dive](layer2_deepdive.md) for patterns, diagrams, and code examples.
>
> **Prerequisite:** [Layer 1](layer1_quickref.md) (PolyNode, Maybe, Builder).

---

You get:
- Items that cross thread boundaries.
- A mailbox that moves ownership between Masters.
- A Master that ties it all together.

No pool yet:
- Builder creates items.
- Builder destroys items.

Mailbox moves them.

---

## Thread and Master

A thread is a thin container that runs exactly one Master.

You
- create the thread.
- pass the Master to it.

From here on, you think in Masters, not threads.

Master
- owns the pools and mailboxes that belong to its domain.
- lives on the heap.
- is the unit of work in matryoshka.

```odin
// Thread proc
run :: proc(arg: rawptr) {
    m := (^Master)(arg)
    master_run(m)
}
```

---

## Mailbox — move items between Masters

Mailbox
- moves `^PolyNode` from one Master to another.
- does not know your types.
- blocking, with optional timeout.
- supports interrupt and close.

Mailbox holds ownership during transit.

It releases ownership to the receiver on success.

### Types

```odin
Mailbox :: distinct ^PolyNode

SendResult :: enum {
    Ok,
    Closed,
    Invalid,
}

RecvResult :: enum {
    Ok,
    Closed,
    Interrupted,
    Already_In_Use,
    Invalid,
    Timeout,
}

IntrResult :: enum {
    Ok,
    Closed,
    Already_Interrupted,
}
```

### New / Dispose

```odin
mbox_new           :: proc(alloc: mem.Allocator) -> Mailbox
matryoshka_dispose :: proc(m: ^Maybe(^PolyNode))
```

---

### send — blocking, ownership transfer

```odin
mbox_send :: proc(mb: Mailbox, m: ^Maybe(^PolyNode)) -> SendResult
```


Handover rules:

| Entry | Rule |
|-------|----------|
| `m == nil` | returns `.Invalid` |
| `m^ == nil` | returns `.Invalid` |
| `m^.id == 0` | returns `.Invalid` |
| `m^ != nil` | proceed |


Result:

| Result | `m^` after return |
|--------|------------------|
| `.Ok` | `nil` — enqueued, ownership transferred |
| `.Closed`, `.Invalid` | unchanged — caller still owns |

**Always check the return value.**
On non-Ok, the item is still yours.
Dispose or retry.

---

## wait_receive — blocking receive, with timeout

```odin
mbox_wait_receive :: proc(mb: Mailbox, out: ^Maybe(^PolyNode), timeout: time.Duration = -1) -> RecvResult
```

`timeout` values:
- `-1` — wait forever (default).
- `0` — non-blocking poll. Returns `.Timeout` immediately if empty.
- `> 0` — wait up to this duration. Returns `.Timeout` on expiry.

Entry contract:

| Entry | Contract |
|-------|----------|
| `out == nil` | returns `.Invalid` |
| `out^ != nil` | returns `.Already_In_Use` — refusing to overwrite |
| `out^ == nil` | proceed |

Result:

| Result | `out^` after return |
|--------|---------------------|
| `.Ok` | non-nil — dequeued, ownership transferred to caller |
| `.Closed`, `.Interrupted`, `.Timeout`, `.Invalid` | unchanged — caller owns nothing |

**Always check the return value.**

On non-Ok, `out^` is unchanged (nil).

Do not proceed.

---

## interrupt — wake without data

```odin
mbox_interrupt :: proc(mb: Mailbox) -> IntrResult
```

Wakes one Master waiting in `mbox_wait_receive`.
The receiver returns `.Interrupted`.

The interrupted flag is **self-clearing**:
- `mbox_wait_receive` clears it when it returns `.Interrupted`.
- A subsequent call to `mbox_wait_receive` will block normally.

| Result | Meaning |
|--------|---------|
| `.Ok` | flag set, waiter will wake |
| `.Closed` | mailbox is already closed — no effect |
| `.Already_Interrupted` | flag already set — no effect |

Not every signal carries data.
Interrupt says "go look".

Think how to communicate *what* changed, this decision is up to you.

One of the possible solutions - to use _second mailbox_ for
transferring "out-of-band" information.

---

## close — orderly shutdown

```odin
mbox_close :: proc(mb: Mailbox) -> list.List
```

- Marks mailbox as closed.
- Further `mbox_send` returns `.Closed`.
- Wakes all Masters waiting in `mbox_wait_receive` — they return `.Closed`.
- Returns all items still in the queue as a `list.List`.
- Returns an empty list if already closed — idempotent.

**Caller must drain the returned list.**

---

## try_receive_batch — non-blocking batch drain

```odin
try_receive_batch :: proc(mb: Mailbox) -> list.List
```

- Non-blocking — never waits.
- Returns all currently available items as `list.List`.
- Returns empty list on: nothing available, closed, interrupted, any error.
- If mailbox is in interrupted state: clears the flag before returning.
- Caller owns all items in the returned list.

**What the list contains:**

- `list.List` is a chain of `^list.Node` — intrusive links, not `^Maybe(^PolyNode)`.
- Each node is a `PolyNode`.
-`PolyNode` embeds `list.Node` via `using` at offset 0.
- Wrap each item in `Maybe` at the processing boundary.

---

## Master — runs on a thread, owns everything

- Master is a user struct.
- It runs on a thread.
- It is the only participant that knows concrete types.

Master holds:
- Builder (from Layer 1).
- At least one Mailbox.
- Any other state it needs.

`newMaster` and `freeMaster` are always written together — they are a pair.

```odin
Master :: struct {
    builder: Builder,
    inbox:   Mailbox,
    alloc:   mem.Allocator,
    // ... other state ...
}
```

Every Master has at least one mailbox.

That is how other Masters talk to it.

```
┌─────────────┐
│  Master     │
│             ├──── inbox ◄════
│             │
└─────────────┘
```

---

## What you learned (Layer 2)

- Absence is also a state — timeout, interrupt.
- Not every signal carries data.
- Shutdown is part of normal flow.
- Builder handles the lifecycle — no pool needed yet.
- Builder is yours.
- Think in Masters, not threads.
- Master is yours.
- Your code, your logic.
- Matryoshka gives you Mailbox.
- Master is what you build on top.
