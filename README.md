![](_logo/horowod_mbox.png)
# Matryoshka — Layered Inter-Thread Communication

The endless inter-threaded game...

[![CI](https://github.com/g41797/matryoshka/actions/workflows/ci.yml/badge.svg)](https://github.com/g41797/matryoshka/actions/workflows/ci.yml)


---


## What Matryoshka really is

- Matryoshka is a set of Russian nesting dolls.
- Each doll is complete by itself.
- You open only the dolls you need right now.
- You stop when you have enough.
- You go deeper only when the next doll solves a real problem you have today.
- You never pay for features you do not use.

---

## Your five dolls5
| Doll | What you get | What you still do not need |
|------|--------------|----------------------------|
| 1    | PolyNode + Maybe | everything else |
| 2    | + Pool + hooks (create, reset, dispose) | mailbox |
| 3    | + simple Mailbox (blocking) | fast loop version |
| 4    | + LoopMailbox (batch + wake) | — full system |
| 5    | full system with all mailboxes | nothing |

**Rule:** open the next doll only because you need it — never because it is there.

---

## Doll 1 — PolyNode + Maybe

You only have one struct and one rule.

```odin
PolyNode :: struct {
    using node: list.Node, // link inside your data
    id:         int,       // 0 is forbidden — tells the type
}
```

Every item you move must put `using poly: PolyNode` as the very first field.

```odin
Chunk :: struct {
    using poly: PolyNode,
    file_id: int,
    data:    [4096]byte,
}
```

Maybe tracks ownership.

```odin
m: Maybe(^PolyNode)
```

- `m^ == nil` → not yours
- `m^ != nil` → yours — you must give it away or clean it up

With only Doll 1 you can already build real things:

- intrusive lists in one thread (no extra allocations)
- simple game entity systems (entities live in one list at a time)
- single-threaded pipelines (read → process → write)
- any system where data moves instead of being shared

No locks. No threads yet. Just clean ownership.

---

## Doll 2 — Pool + hooks

Now you add recycling.

Pool holds items.
It never knows your types.
All smarts live in your hooks.

```odin
PoolHooks :: struct {
    ctx:    rawptr,
    on_get: proc(ctx: rawptr, id: int, count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, count: int, m: ^Maybe(^PolyNode)),
}
```

`on_get` creates or resets.
`on_put` decides: keep it or throw it away.

You start simple:

```odin
on_get: always new(...)
on_put: always free(...)
```

Same system as Doll 1, just no leaks.

Later you grow the same hooks:

- count > 400 → dispose (backpressure)
- reset fields before reuse
- use your own arena
- add stats

Pool code never changes.
Only your hooks become smarter.

With Doll 1 + 2 you can build:

- compression pipeline (chunks live forever in the pool)
- game object pool (enemies, bullets, particles)
- any system that creates and destroys the same shapes again and again

Still one thread. Still no mailbox.

---

## Doll 3 — Mailbox

Now you add threads.

Mailbox moves items between threads.

One sender thread.
One receiver thread.

You call:

- `mbox_send` → ownership leaves you
- `mbox_wait_receive` → ownership comes to you

- It blocks when empty.
- And you can use timeout.
- It wakes when something arrives.
- And you can interrupt receive side without send.

You still use the same Pool from Doll 2.

With Doll 1 + 2 + 3 you can now build the full compression example:

Main thread
- reads file
- gets chunk from pool
- sends ==>

Worker thread
- waits
- ==> receives
- compresses
- sends progress  back  ==>
- sends compressed back  ==>


Main thread
- ==> receives progress and updates bar
- ==> receives data and writes file)

No shared arrays.
No locks in your code.
Just
- “get → fill → send” and
- “wait → process → put”.

---

## Doll 4 — LoopMailbox (fast batch + wake)

When your receiver is a game loop or event loop you open this doll.

- No blocking.
- No mutex on the receive side.
- You call `try_receive_batch` once per frame.
- You get all waiting items at once.

Optional WakeUper tells the sender “something arrived” without blocking.

Same ownership rules.
Same Pool.
Same `PolyNode`.

You use it when:

- game loop (60 times per second)
- network reactor
- audio callback (must never block)

The simple Mailbox from Doll 3 still works for normal workers.

You choose the doll that fits your loop.

---

## How the same system grows

Start with Doll 1.
Make a single-thread game that moves entities in one list.

Open Doll 2.
Add a pool.
Now you recycle enemies instead of new/free every time.

Open Doll 3.
Add one worker thread.
Now compression runs in background.

If your task requires several workers - add.
Remember Mailbox supports safe multithreaded  [FanIn-FanOut](https://medium.com/@kapoorjasdeep/fan-out-and-fan-in-the-unsung-heroes-of-system-design-2f8a46933518) patterns.

Open Doll 4.
Change the main loop to use LoopMailbox.
Now the UI stays smooth at 60 fps.

Every step uses exactly the same vocabulary:

- get from pool
- fill
- send
- receive
- put back

Only the mailbox changes when you need speed.

---

## Names you can use

We give clear short names so you never guess.

| Old thinking name | Matryoshka name | What it does |
|-------------------|-----------------|--------------|
| queue             | Mailbox         | moves data between threads |
| fast queue        | LoopMailbox     | batch receive for loops |
| object pool       | Pool            | recycles your structs |
| node              | PolyNode        | the link inside every item |
| ownership flag    | Maybe           | tells who owns the item now |

Use these names in your code and comments.
Everyone on the team will understand.

---

## The compression picture again (with dolls)

```
Main (Doll 3)
  ↓ Chunk (PolyNode)
Mailbox (Doll 3)
  ↓
Worker 1..3
  ↓ Progress + CompressedChunk
Mailbox (Doll 3 or 4)
  ↓
Main (Doll 3 or 4)
```

All items come from one Pool (Doll 2).
All transfers use Maybe ownership.

---

## What changes in your head

Before Matryoshka you think:
- who locked what
- who waits
- who frees

With Matryoshka you think:
- where does this chunk go next
- who owns it right now
- when do I return it to the pool

That is the only real change.

---

## You can stop at any doll

Need only lists in one thread?
Stop at Doll 1.

Need recycling without threads?
Stop at Doll 2.

Need worker threads?
Stop at Doll 3.

Need smooth game loop?
Stop at Doll 4.

The system is complete at every step.

---

## Takeaway

Matryoshka is not a big library.

It is five small complete pieces.

You open them one by one.

You speak the same simple words at every level:

- I get it from the pool.
- I fill it.
- I send it.
- I receive it.
- I put it back.

If that sentence describes your whole program,
the design works.

That is all.
