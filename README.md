![](_logo/gold_mbox.png)

# odin-mbox

[![CI](https://github.com/g41797/odin-mbox/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/odin-mbox/actions/workflows/ci.yml)

Inter-thread communication for Odin. Intrusive. Thread-safe. Zero-allocation.

Port of [mailbox](https://github.com/g41797/mailbox) (Zig). Used by [otofu](https://github.com/g41797/otofu).

---

## A bit of history, a bit of theory

Mailboxes are one of the fundamental parts of the [actor model originated in **1973**](https://en.wikipedia.org/wiki/Actor_model):
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
|     L/W/M   |    *Zig*    |

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
| Interrupt without close | no | yes — `interrupt()` (self-clearing) |
| Message ownership | channel owns the copy | caller owns; mailbox borrows node while queued |

**Caller owns memory; mailbox borrows node while queued** means: `mbox` never copies your message. It links your struct directly into the queue. You own the memory from creation to destruction. The mailbox only borrows the `node` field while the message is queued. No allocator is ever touched inside mailbox operations. `close()` returns any unprocessed messages to the caller as a `list.List`.

**One place only:** a `list.Node` can only be in one list at a time. Do not send a message that is already queued somewhere else. Remove it from any other intrusive structure before sending.

**nbio integration** is the strongest reason to use `mbox`. `Loop_Mailbox` wakes an nbio event loop when a message arrives. `core:sync/chan` cannot do this.

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

To use mbox your struct must have a field named `node` of type `list.Node`. The name is fixed.

```odin
import list "core:container/intrusive/list"

My_Msg :: struct {
    node: list.Node,  // required — name must be "node", type must be list.Node
    data: int,
}
```

The compiler enforces this at compile time via `where` clause. Wrong struct = compile error.

---

## Two mailbox types

| Type | For | How it waits |
|---|---|---|
| `Mailbox($T)` | Worker threads | `sync.Cond` — blocks the thread |
| `Loop_Mailbox($T)` | nbio event loops | `nbio.wake_up` — wakes the loop |

Both are thread-safe. Both do zero allocations inside mailbox operations.

### Quick start — worker thread mailbox

```odin
import mbox "path/to/odin-mbox"

// sender thread:
msg := My_Msg{data = 42}
mbox.send(&mb, &msg)

// receiver thread (blocks until message arrives):
got, err := mbox.wait_receive(&mb)
```

### Quick start — nbio loop mailbox

```odin
// setup (once, on the loop thread):
loop_mb: mbox.Loop_Mailbox(My_Msg)
loop_mb.loop = nbio.current_thread_event_loop()

// sender thread:
mbox.send_to_loop(&loop_mb, &msg)

// nbio loop — drain on wake:
for {
    msg, ok := mbox.try_receive_loop(&loop_mb)
    if !ok { break }
    // process msg
}
```

---

## API

### `Mailbox($T)`

| Proc | Returns | Description |
|---|---|---|
| `send(&mb, &msg)` | `bool` | Add message. Returns false if closed. |
| `wait_receive(&mb, timeout=-1)` | `(^T, Mailbox_Error)` | Block until message, timeout, or interrupt. Use `timeout=0` for non-blocking poll. |
| `interrupt(&mb)` | `bool` | Wake one waiter. Returns false if already interrupted or closed. Self-clearing. |
| `close(&mb)` | `(list.List, bool)` | Block sends. Wake all waiters with `.Closed`. Return remaining messages. |

`Mailbox_Error` values: `None`, `Timeout`, `Closed`, `Interrupted`.

### `Loop_Mailbox($T)`

| Proc | Returns | Description |
|---|---|---|
| `send_to_loop(&mb, &msg)` | `bool` | Add message, wake the loop. Returns false if closed. |
| `try_receive_loop(&mb)` | `(^T, bool)` | Return message if available. Never blocks. |
| `close_loop(&mb)` | `(list.List, bool)` | Block sends. Wake loop once. Return remaining messages. |
| `stats(&mb)` | `int` | Approximate pending message count. |

---

## Build and test

```sh
./build_and_test.sh
```

Runs 5 optimization levels: `none`, `minimal`, `size`, `speed`, `aggressive`.

Each level builds the root lib, builds examples, runs tests, and runs doc checks.

---

## Folder structure

```
odin-mbox/
  mbox.odin          # Mailbox — worker thread mailbox
  loop_mbox.odin     # Loop_Mailbox — nbio loop mailbox
  doc.odin           # Package doc and usage examples
  examples/          # Runnable examples (negotiation, stress)
  tests/             # @test procs
  design/            # Design docs

```

---

## Design docs

- [mailbox_design.md](design/mailbox_design.md) — architecture notes
- [mbox_examples.md](design/mbox_examples.md) — usage patterns

---

## License

MIT

---

## Last warning

First rule of multithreading:
> **If you can do without multithreading — do without.**

*Powered by* [OLS](https://github.com/DanielGavin/ols) + [Odin](https://odin-lang.org/)
