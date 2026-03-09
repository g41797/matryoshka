# mbox — Inter-thread mailbox for Odin

Inter-thread mailbox library for Odin. Thread-safe. Zero-allocation.

Port of [mailbox](https://github.com/g41797/mailbox) (Zig).

---

## A bit of history, a bit of theory

Mailboxes are one of the fundamental parts of the [actor model originated in **1973**](https://en.wikipedia.org/wiki/Actor_model):
> An actor is an object that carries out its actions in response to communications it receives.
> Through the mailbox mechanism, actors can decouple the reception of a message from its elaboration.
> A mailbox is nothing more than the data structure (FIFO) that holds messages.

I first encountered MailBox in the late 80s while working on a real-time system:
> "A **mailbox** is an object that can be used for inter-task communication.
> When task A wants to send an object to task B, task A must send the object to the mailbox,
> and task B must visit the mailbox, where, if an object isn't there,
> it has the option of *waiting for any desired length of time*..."
>
> **iRMX 86™ NUCLEUS REFERENCE MANUAL** *Copyright © 1980, 1981 Intel Corporation.*

Since then, I have used it in:

|     OS      | Language(s) |
|:-----------:|:-----------:|
|    iRMX     |  *PL/M-86*  |
|     AIX     |     *C*     |
|   Windows   |  *C++/C#*   |
|    Linux    |    *Go*     |
|     All     |    *Zig*    |

**Now it's Odin time!!!**

---

## Why?

If your threads run in "Fire and Forget" mode, you don't need a mailbox.

But in real multithreaded applications, threads communicate as members of a work team.

Odin already has `core:sync/chan` — Go-style typed channels. If that is enough for you, use it.

**mbox** is for when you need more:

| | `core:sync/chan` | `mbox` |
|---|---|---|
| Allocation per message | yes — copies the value | zero — intrusive link |
| nbio integration | no | yes — `Loop_Mailbox` |
| Receive timeout | no | yes |
| Interrupt without close | no | yes — `interrupt()` + `reset()` |
| Message ownership | channel owns the copy | sender always owns |

**Sender always owns** means: `mbox` never copies your message. It links your struct directly into the queue. You own the memory from creation to destruction. The mailbox only borrows the `node` field while the message is queued. No allocator is ever touched inside mailbox operations.

**nbio integration** is the strongest reason to use `mbox`. `Loop_Mailbox` wakes an nbio event loop when a message arrives. `core:sync/chan` cannot do this. If you build an nbio-based server, there is no alternative.

---

## What "intrusive" means

A normal queue wraps your data in a node it allocates:

```odin
// The queue allocates one of these per message (behind the scenes):
Queue_Node :: struct {
    next: ^Queue_Node,
    data: ^My_Msg,     // pointer to your data — two objects per message
}
```

An intrusive queue does not allocate anything. The link lives inside your struct:

```odin
// YOUR struct contains the link:
My_Msg :: struct {
    node: list.Node,   // the link IS your struct — one object, zero allocation
    data: int,
}
```

The queue just connects the `node` fields that are already inside your structs.

Because of this:
- Zero allocations per message.
- You own the memory. You decide the lifetime.
- Your struct must stay alive while it is in the mailbox.

### Your struct contract

To use mbox your struct must embed a `node` field of type `list.Node`.

```odin
import list "core:container/intrusive/list"

My_Msg :: struct {
    node: list.Node,  // required — name must be "node"
    data: int,
}
```

- The field name is fixed: `node`.
- The field type is fixed: `list.Node` from `core:container/intrusive/list`.
- The compiler checks this at compile time via `where` clause.

---

## Two mailbox types

### `Mailbox($T)` — for worker threads

Blocks using a condition variable. The thread sleeps until a message arrives.

```odin
mb: mbox.Mailbox(My_Msg)

// sender:
mbox.send(&mb, &msg)

// receiver (blocks):
got, err := mbox.wait_receive(&mb)

// receiver (non-blocking):
got, ok := mbox.try_receive(&mb)
```

Error values: `None`, `Timeout`, `Closed`, `Interrupted`.

### `Loop_Mailbox($T)` — for nbio event loops

Non-blocking. Wakes the nbio event loop using `nbio.wake_up`.

```odin
loop_mb: mbox.Loop_Mailbox(My_Msg)
loop_mb.loop = nbio.current_thread_event_loop()

// sender (from any thread):
mbox.send_to_loop(&loop_mb, &msg)

// nbio loop — drain on wake:
for {
    msg, ok := mbox.try_receive_loop(&loop_mb)
    if !ok { break }
    // handle msg
}
```

---

## API summary

### `Mailbox($T)`

| Proc | Description |
|---|---|
| `send(&mb, &msg)` | Add message. Returns false if closed. |
| `try_receive(&mb)` | Return message if available. Never blocks. |
| `wait_receive(&mb, timeout?)` | Block until message, timeout, or interrupt. |
| `interrupt(&mb)` | Wake all waiters with `.Interrupted`. |
| `close(&mb)` | Block new sends. Wake all waiters with `.Closed`. |
| `reset(&mb)` | Clear closed and interrupted flags. Allow reuse. |

### `Loop_Mailbox($T)`

| Proc | Description |
|---|---|
| `send_to_loop(&mb, &msg)` | Add message. Wake loop if it was empty. Returns false if closed. |
| `try_receive_loop(&mb)` | Return message if available. Never blocks. |
| `close_loop(&mb)` | Block new sends. Wake loop one last time. |
| `stats(&mb)` | Approximate pending count (not locked). |

---

## Eat your own dog food

I am using mbox in my own Odin projects:
- [otofu](https://github.com/g41797/otofu) — Odin port of the tofu messaging system

---

## Last warning

First rule of multithreading:
> **If you can do without multithreading — do without.**

*Powered by* [OLS](https://github.com/DanielGavin/ols) + [Odin](https://odin-lang.org/)
