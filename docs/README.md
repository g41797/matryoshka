# odin-mbox

The endless inter-threaded game...

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

Mailboxes are an old idea. They were part of the [actor model in **1973**](https://en.wikipedia.org/wiki/Actor_model).

I have used this pattern in many systems:

- **iRMX**: PL/M-86
- **AIX**: C
- **Windows**: C++/C#
- **Linux**: [Go](https://github.com/g41797/kissngoqueue)
- **L/W/M**: [Zig](https://github.com/g41797/mailbox)

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

---

## Two mailbox types

- **Mailbox($T)**: For worker threads. Blocks the thread until a message arrives.
- **Loop_Mailbox($T)**: For nbio loops. Wakes the loop. Never blocks the thread.

Both are thread-safe. Both have zero allocations for sending or receiving.

---

## Examples

Check the [examples/](https://github.com/g41797/odin-mbox/tree/main/examples) directory for:

- **Endless Game**: 4 threads pass a single message in a circle.
- **Negotiation**: Request and reply between a worker thread and an `nbio` loop.
- **Life and Death**: Full flow: from allocation to cleanup.
- **Stress Test**: Many threads sending thousands of messages to one receiver.
- **Interrupt**: How to wake a waiting thread without sending a message.
- **Close**: Stop the game and get back all unprocessed messages.

## Credits

- **Docs & Website Generation**: All "black magic" stolen from [odin-tree-sitter](https://github.com/laytan/odin-tree-sitter).

---

## Learn more

- [Architecture details](https://github.com/g41797/odin-mbox/blob/main/design/mailbox_design.md)
- [Common usage patterns](https://github.com/g41797/odin-mbox/blob/main/design/mbox_examples.md)

---

## Forewarned is forearmed

Remember the *First Rule of Multithreading*:
> **If you can do without multithreading — do without.**
