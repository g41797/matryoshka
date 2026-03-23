# matryoshka Demo: Ownership-Driven Data Flow (Compression Pipeline)

This document shows how to build a simple multi-threaded process using `matryoshka`.

The goal is not to demonstrate APIs, but to show a different way of thinking:

> Developers stop reasoning about locks and start reasoning about
> **data flow, ownership, and lifecycle**

---

# 1. The Problem (Real Conversation)

```text
Main: I need to compress large files.

Worker: Send me file chunks.

Main: Whole files?

Worker: No, chunks. I process data incrementally.

Main: What happens after I send a chunk?

Worker: I start processing it immediately.

Main: How do I track progress?

Worker: While I work, I'll report how many bytes I've processed.

Main: And the result?

Worker: I'll send compressed chunks back.

Main: Can I send multiple files?

Worker: Yes. Just mark chunks with a file ID.

Main: So you're processing and communicating at the same time?

Worker: Exactly. Work never blocks communication.
```

---

# 2. The Picture

```text
          +------------------+
          |     Main         |
          | (File Reader)    |
          +------------------+
                    |
                    |  Chunk(file_id, offset)
                    ▼
        =========================
        ||     Mailbox        ||
        =========================
          │        │        │
          ▼        ▼        ▼
     +--------+ +--------+ +--------+
     |Worker 1| |Worker 2| |Worker 3|
     |Compress| |Compress| |Compress|
     +--------+ +--------+ +--------+
          │        │        │
          └────┬───┴───┬────┘
               ▼       ▼
        =========================
        ||     Mailbox        ||
        =========================
                    |
                    ▼
          +------------------+
          |     Main         |
          | (Writer)         |
          +------------------+
```

This is the system.

No shared state. Only moving data.

---

# 3. What Actually Moves

We don't send "jobs". We send real data.

All items embed `PolyNode` at offset 0. This is the intrusive base — it carries the queue link and a user-defined `id` that identifies the concrete type at runtime.

```odin
PolyNode :: struct {
    using node: intrusive.Node,  // offset 0 — queue link
    id: int,                     // identifies concrete type — stamped by pool on acquire
}

FlowId :: enum { Chunk, Progress, CompressedChunk }

Chunk :: struct {
    using poly: PolyNode,  // offset 0
    file_id: int,
    offset:  int,
    data:    []u8,
}

Progress :: struct {
    using poly: PolyNode,  // offset 0
    file_id:         int,
    processed_bytes: int,
}

CompressedChunk :: struct {
    using poly: PolyNode,  // offset 0
    file_id: int,
    offset:  int,
    data:    []u8,
}
```

All items are:

* intrusive — node embedded inside item, no separate allocation
* moved by pointer — zero-copy
* owned by exactly one participant at a time
* type-identified at runtime via `poly.id`

One pool. One mailbox. All three item kinds travel through the same pipe.

---

# 4. How Developers Talk

Without `matryoshka`, developers say:

```text
lock this
wait here
signal there
protect shared state
```

With `matryoshka`, the same system becomes:

```text
I'll get a chunk from the pool
I'll process it
I'll send you the result
I'll return it to the pool
```

> Synchronization still exists — but it is no longer part of the conversation.

---

# 5. The Core Building Blocks

* **Masters** — own logic, state, allocator, pool, and mailboxes
* **Mailboxes** — type-erased — move `^PolyNode` between Masters
* **Pools** — type-erased — manage lifecycle per `id` via hooks
* **Items** — the data that moves — all embed `PolyNode` at offset 0

Each has a single responsibility.

---

# 6. Flow (What Actually Happens)

From the outside, the system behaves like this:

```text
Main reads file
  → pool_get(id=Chunk, mode=Always)
  → fill Chunk
  → mbox_send

Worker receives ^PolyNode
  → switch poly.id
  → case Chunk: cast, process
      → pool_get(id=Progress) → send progress
      → pool_get(id=CompressedChunk) → send result
  → pool.put

Main receives ^PolyNode
  → switch poly.id
  → case Progress:        update display → pool.put
  → case CompressedChunk: write output  → pool.put
```

Processing and communication are naturally interleaved.

Nothing blocks the whole system.

---

# 7. Ownership (The Rule That Makes It Work)

All transfers follow one rule:

> Ownership must move.

When sending:

```odin
m: Maybe(^PolyNode)
pool_get(&p, &m, int(FlowId.Chunk), .Always)
defer pool_dispose(&p, &m)     // no-op if sent, frees if stuck

// fill item ...
c := (^Chunk)(m.?)
c.file_id = file_id
c.offset  = offset

mbox_send(&mb, &m)
// success → m^ = nil — sender no longer holds it
// failure → m^ unchanged — dispose fires on exit
```

* If send succeeds → sender loses ownership (`m^ = nil`)
* If send fails → sender still owns the item, dispose cleans up

This guarantees:

* no double free
* no lost data
* no shared mutable state

---

# 8. Memory Lifecycle (Pools)

All items follow:

```text
pool_get(id, mode) → factory(ctx, id) → item stamped with id
     ↓
fill item
     ↓
mbox_send → ownership transfers
     ↓
mbox.wait_receive → switch poly.id → process
     ↓
pool.put → reset(ctx, node) → back to free list
     ↓
on shutdown: mbox.close → returns list → pool_dispose each
```

Pool hooks carry `ctx` — user context passed to every hook call:

```odin
Pool_Hooks :: struct {
    ctx:     rawptr,
    factory: proc(ctx: rawptr, id: int) -> (^PolyNode, bool),
    reset:   proc(ctx: rawptr, node: ^PolyNode),
    dispose: proc(ctx: rawptr, m: ^Maybe(^PolyNode)),
}
```

`ctx` carries the Master — factory reaches the allocator through it.
Hooks are always called outside the pool mutex — user is responsible for any synchronization inside hooks.

Pools ensure:

* no constant allocation
* predictable performance
* clear ownership boundaries

---

# 9. What This Is NOT

This system does **not** remove synchronization.

Internally:

* mailboxes use locks
* operations may block or timeout

But:

> Synchronization is isolated inside well-defined components
> and never leaks into domain logic

---

# 10. What This Changes

Instead of thinking:

```text
Who owns this memory?
Who holds the lock?
Who is waiting?
```

You think:

```text
Where does this chunk go next?
Who owns it now?
When do I return it?
```

---

# 11. Why This Scales

You can extend the system without changing the model:

* more workers → just add Masters
* multiple files → just add file_id
* different processing stages → add more mailboxes
* new item kinds → add to `FlowId` enum and hooks switch
* backpressure → `WakeUper` signals producer to switch `id` or skip

The vocabulary stays the same.

---

# 12. Poly-Items — How It Works

Pool and mailbox are type-erased. They operate on `^PolyNode` only.
All type knowledge lives in user code.

```
itc delivers:   ^PolyNode + poly.id
user decides:   what to cast to, what to do, which pool to return to
```

On the receiver side:

```odin
m: Maybe(^PolyNode)
mbox.wait_receive(&mb, &m)
defer pool_dispose(&p, &m)     // safety net

switch FlowId(m.?.id) {
case .Chunk:
    c := (^Chunk)(m.?)
    // process
    pool.put(&p, &m)

case .Progress:
    pr := (^Progress)(m.?)
    // update display
    pool.put(&p, &m)

case .CompressedChunk:
    cc := (^CompressedChunk)(m.?)
    // write output
    pool.put(&p, &m)
}
```

Compiler enforces exhaustiveness on the switch.
No dynamic typing. No runtime reflection. All types known at compile time.

---

# 13. Takeaway

This is not just a library.

It is a way to build systems where:

* data moves instead of being shared
* ownership is always clear
* developers speak the same language

```text
"I'll get a chunk from the pool,
process it,
and send it back."
```

If that sentence is enough to understand the system,

the model works.
