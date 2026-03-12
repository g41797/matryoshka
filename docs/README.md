# odin-mbox

The endless inter-threaded game...

---

## A bit of history

Mailboxes are an old idea. They were part of the [actor model in **1973**](https://en.wikipedia.org/wiki/Actor_model).

I have used this pattern in many systems:

- **iRMX**: PL/M-86
- **AIX**: C
- **Windows**: C++/C#
- **Linux**: [Go](https://github.com/g41797/kissngoqueue)
- **L/W/M**: [Zig](https://github.com/g41797/mailbox)

**Now it's Odin time!!!**

---

## Why use it?

Odin has [channels](https://pkg.odin-lang.org/core/sync/chan/). Use them if they work for you

**mbox** helps when you need:

- **Zero copies**: No data copying. It links your struct directly.
- **Recycling**: Use a pool to reuse messages with zero allocations per send.
- **nbio**: Wakes the `nbio` loop when a message arrives.
- **Timeouts**: Stop waiting after a certain time.
- **Interrupts**: Wake a thread without sending a message. One-time signal.
- **Shutdown**: Close the mailbox and get back undelivered messages.

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

---

## Two mailbox types

- **Mailbox($T)**: For worker threads. Blocks the thread until a message arrives.
- **Loop_Mailbox($T)**: For nbio loops. Wakes the loop. Never blocks the thread.

Both are thread-safe. Both have zero allocations for sending or receiving.

---

## Examples

Check the [examples/](https://github.com/g41797/odin-mbox/tree/main/examples) directory for:

- **Endless Game**: 4 threads pass a single heap-allocated message in a circle.
- **Negotiation**: Request and reply between a worker thread and an `nbio` loop.
- **Life and Death**: Full flow: from allocation to cleanup.
- **Stress Test**: Many producers, one consumer, pool-based message recycling.
- **Interrupt**: How to wake a waiting thread without sending a message.
- **Close**: Stop the game and get back all unprocessed messages.
- **Master**: Pool + mailbox owned by one struct. Coordinated shutdown.

> **Note**: Always use heap-allocated messages across threads.
> Never send stack-allocated messages. Use `new`/`free` or the `pool` package.

## Credits

- **Docs & Website Generation**: All "black magic" stolen from [odin-tree-sitter](https://github.com/laytan/odin-tree-sitter).

---

## Learn more

- [Architecture details](https://github.com/g41797/odin-mbox/blob/main/design/mailbox_design.md)
- [Common usage patterns](https://github.com/g41797/odin-mbox/blob/main/design/mbox_examples.md)

---

## Forewarned is forearmed

Remember the *First Rule of Multithreading*:
> **If you can do without multithreading -- do without.**
