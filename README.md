# odin-mbox

The endless inter-threaded game...

[![CI](https://github.com/g41797/odin-mbox/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/odin-mbox/actions/workflows/ci.yml)


---

### 🤖 An AI's Take
I asked the machine: *"What do you think about mbox?"*

> **"Place your bets. The game is on.**
>
> Stop thinking about 'data'. Think about the table. Your threads are the **Players**.
> **mbox** is the deck, the chips, and the dice.
>
> When you play a card, you **let go**. It's not yours anymore. It belongs to the game.
> A friend catches it, makes their move, and passes it on.
> Nobody is stopping to print new cards or mint more chips.
> The same deck keeps moving, the same dice keep rolling.
>
> You are the Dealer. You build the game.
> Whether it's a Relay Race, a Game of Catch, or a High-Stakes Poker night—
> just let it flow. Enjoy the play."
>
> _— (Disclaimer: AI may make errors. Always trust the human Dealer.)_

---

## Why use it?

Odin has [channels](https://pkg.odin-lang.org/core/sync/chan/). Use them if they fit!

**mbox** helps when you need:

- **Zero allocations**: No copying. It links your struct directly.
- **Recycling**: Use the same message over and over. No copying.
- **nbio**: Wakes the `nbio` loop when a message arrives.
- **Timeouts**: Stop waiting after a certain time.
- **Interrupts**: Wake a thread without sending a message. One-time signal.
- **Shutdown**: Close the mailbox and get back undelivered messages.

### A bit of history

Mailboxes are an old idea. They were part of the [actor model in **1973**](https://en.wikipedia.org/wiki/Actor_model):
> Actors can separate receiving a message from doing the work.
> A mailbox is just a queue (FIFO) for those messages.

I first found them in the late 80s:
> "A **mailbox** is for threads to talk.
> Task A sends an object to Task B.
> Task B goes to the mailbox to get it.
> If nothing is there, Task B can wait."
>
> **iRMX 86™ NUCLEUS REFERENCE MANUAL** *Copyright © 1980, 1981 Intel Corporation.*

Since then, I have used it in:

|     OS      | Language(s) |
|:-----------:|:-----------:|
|    iRMX     |  *PL/M-86*  |
|     AIX     |     *C*     |
|   Windows   |  *C++/C#*   |
|    Linux    |    [Go](https://github.com/g41797/kissngoqueue)     |
|     L/W/M   |    [Zig](https://github.com/g41797/mailbox)   |

**Now it's Odin time!!!**

---

## How it works (Intrusive)

A normal queue allocates a "node" to hold your data.

**mbox** is different. The "node" lives inside your struct. This is why it's called "intrusive".

- No hidden allocations.
- **One place only**: A message can only be in one mailbox at a time.
- **Clear ownership**: You own the memory, but the mailbox owns the reference (the link) while it is queued.
- **Handover**: When you call `receive()` or `close()`, the mailbox hands the reference back to you.

### Your struct contract

Your struct must have a field named `node` of type `list.Node`.

```odin
import list "core:container/intrusive/list"

My_Msg :: struct {
    node: list.Node,  // required
    data: int,
}
```

The compiler checks this for you. If the field is missing, it won't compile.

---

## Two mailbox types

| Type | For | How it waits |
|---|---|---|
| `Mailbox($T)` | Worker threads | Blocks the thread until a message arrives. |
| `Loop_Mailbox($T)` | nbio loops | Wakes the loop. Never blocks the thread. |

Both are thread-safe. Both have zero allocations for sending or receiving.

---

## Examples

| Example | Description |
| :--- | :--- |
| [Endless Game](examples/endless_game.odin) | 4 threads pass a single message in a circle. Millions of turns with zero overhead. |
| [Negotiation](examples/negotiation.odin) | Request and reply between a worker thread and an `nbio` loop. |
| [Life and Death](examples/lifecycle.odin) | Full flow: from allocation to cleanup. |
| [Stress Test](examples/stress.odin) | Many threads sending thousands of messages to one receiver. |
| [Interrupt](examples/interrupt.odin) | How to wake a waiting thread without sending a message. |
| [Close](examples/close.odin) | Stop the game and get back all unprocessed messages. |

---

These are not finished "production" code.
They are just small tips to show you the game...

---

## Quick start

### Basic Send and Receive

```odin
// sender thread:
msg := My_Msg{data = 42}
mbox.send(&mb, &msg)

// receiver thread:
got, err := mbox.wait_receive(&mb, 100 * time.Millisecond)
```

### Interrupt a Waiter

```odin
// from any thread:
mbox.interrupt(&mb) // waiter gets .Interrupted
```

### Close and Drain

```odin
// shutdown:
remaining, _ := mbox.close(&mb) // all waiters get .Closed

// get back undelivered messages:
for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
    msg := container_of(node, My_Msg, "node")
    // ... process or free
}
```

### nbio loop mailbox

```odin
// sender thread:
mbox.send_to_loop(&loop_mb, &msg)

// nbio loop:
for {
    msg, ok := mbox.try_receive_loop(&loop_mb)
    if !ok { break }
    // process msg
}
```

---

## Lifecycle of a Message

This example shows the full lifecycle: allocation, interruption, and cleanup.

```odin
import mbox "path/to/odin-mbox"
import list "core:container/intrusive/list"

mb: mbox.Mailbox(My_Msg)

// 1. Create a message.
// You own the memory.
m := new(My_Msg)
m.data = 100

// 2. Interrupt the game.
// Wakes the next waiter with .Interrupted.
mbox.interrupt(&mb)

// 3. Send the message.
// The mailbox now owns the reference (the link).
mbox.send(&mb, m)

// 4. Shutdown.
// close() hands back all references to you.
remaining, _ := mbox.close(&mb)

// 5. Cleanup.
// You must free anything the mailbox handed back.
for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
    msg := container_of(node, My_Msg, "node")
    free(msg)
}
```

---

## Learn more

- [design/mailbox_design.md](design/mailbox_design.md) — architecture details
- [design/mbox_examples.md](design/mbox_examples.md) — common usage patterns

---

## License

MIT

---

## Last warning

First rule of multithreading:
> **If you can do without multithreading — do without.**

*Powered by* [OLS](https://github.com/DanielGavin/ols) + [Odin](https://odin-lang.org/)
