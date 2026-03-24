# matryoshka — Layered Design

> One layer at a time. Stop when you have enough.

> **This is the teaching companion.**
> The normative specification lives in `design.md`.
> When this file contradicts `design.md` — `design.md` wins.

---

## Document Writing Rules

When editing this document, follow these rules:

**Sentences**
- One idea per line.
- Split compound sentences — do not chain clauses with commas.
- Do not pack a full explanation into one sentence.
- Use bullets or short sequential sentences instead.
- If you feel the urge to write "which", "that", or "because" mid-sentence — stop. Split.

**Language**
- Write for non-English developers.
- No academic words: "semantics", "structural", "contractual", "mechanism", "protocol".
- If you would not say it to a colleague at a whiteboard — rewrite it.

**Lists**
- Use bullet lists for sets of items, attributes, or steps.
- Use numbered lists only when order matters for correctness.

**Sequential steps**
- Write as a bullet list, not as a run-on sentence.
- Label the context: `Send side:` / `Receive side:` / `Algorithm:` etc.

**Tables**
- Use for result codes, mode behavior, and rules.
- Keep column count minimal — two or three columns maximum.

**Prose paragraphs**
- Reserve for motivation and explanation, not for API contracts.
- API contracts go in tables or bullet lists.

**Source files**
- Source files know nothing about layers — no layer references in comments or docs.
- No forward references to terms not yet defined in the document.
- Always use the two-value form to read the inner value of a `Maybe`: `ptr, ok := m.?`
- Never use the single-value form `ptr := m.?` — it panics if nil.
- Never cast or dereference around `.?`.

**Cross-layer references**
- A layer may reference earlier layers.
- A layer must never reference later layers.
- Within a layer, do not mention concepts defined later in the same layer.

---

## How to read this document

Matryoshka is a set of nested dolls.
Each doll is complete by itself.

You open only the dolls you need right now.
You stop when you have enough.
You go deeper only when the next doll solves a real problem you have today.

| Layer | What you have | What you don't need yet |
|-------|--------------|------------------------|
| 1 | `PolyNode` + `Maybe` + `Builder` | mailbox, pool |
| 2 | + Mailbox + Master | pool |
| 3 | + Pool + Recycler | — full matryoshka |

**The rule:** move to the next layer because you need it — not because it is there.

**The mantra:**
- Code.
- Fail.
- Learn.
- Fix.
- Improve.

At each layer you use what you already have.
You extend it.
Or you throw it away and rewrite.
That is fine.

**Naming:**
- _Matryoshka_ — the brand name.
- _itc_ (inter-thread communication) — the short name for code and tags.
- Code tags like `[itc: defer-put-early]` use `itc` because it is shorter.

---

# Layer 1 — PolyNode + Maybe + Builder

You get:
- Items that travel.
- Ownership that is visible.
- A factory that creates and destroys.

No threads. No queues. No pools.
Just clean ownership in one thread.

---

## PolyNode — the traveling struct

```odin
import list "core:container/intrusive/list"

PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int,       // must be != 0, describes the type of user data
}
```

Reminder — `list.Node`:
```odin
Node :: struct {
    prev, next: ^Node,
}
```

Every type that travels through matryoshka embeds `PolyNode` at **offset 0** via `using`:

```odin
Event :: struct {
    using poly: PolyNode,   // offset 0 — required
    code:       int,
    message:    string,
}

Sensor :: struct {
    using poly: PolyNode,   // offset 0 — required
    name:       string,
    value:      f64,
}
```

`using` magic:
- `ev.id == ev.poly.id`
- `ev.next == ev.poly.next`

### Offset 0 rule

The cast `(^Event)(node)` is valid only if `PolyNode` is first.
This is a convention.
You follow it.
Matryoshka has no compile-time check for this.

### Id rule

`id` must be != 0.
Zero is the zero value of `int`.
An uninitialized `PolyNode` would have `id == 0`.
That is how you catch missing initialization — immediately.

Set `id` once at creation.
Use an enum:

```odin
ItemId :: enum int {
    Event  = 1,  // must be != 0
    Sensor = 2,
}
```

### Intrusive

A **non-intrusive** queue allocates a wrapper node around your data:

```
[ queue node ] → [ your struct ]   ← two allocations, two indirections
    .next
    .data  ──────────────────────►
```

An **intrusive** queue puts the link inside your struct:

```
[ your struct                 ]   ← one allocation
    PolyNode.node.next ──────────► next item in queue
    PolyNode.id
    your fields...
```

With `using poly: PolyNode` at offset 0, your struct *is* the node.
No wrapper.
No extra allocation.
No extra indirection compared to non-intrusive.

### Services don't know your types

Matryoshka services receive `^PolyNode`, store `^PolyNode`, return `^PolyNode`.
They don't know what is inside.

All concrete type knowledge lives in user code.

`PolyNode.id` tells you the type. It makes the cast safe:
- Zero is always invalid.
- Unknown id is a programming error.
- Known id → you can cast. Correctness is on you.

### One place at a time

`list.Node` has exactly one `prev` and one `next`.
Linking an item into two lists at the same time corrupts both.
An item lives in exactly one place at a time.
The link structure makes correct use natural — one `prev`, one `next`, one place.
But nothing stops you from inserting the same node twice.
That would corrupt both lists.
This is discipline, not enforcement.

---

## Maybe(^PolyNode) — who owns this item

```
m: Maybe(^PolyNode)

m^ == nil                       m^ != nil
┌───────────┐                   ┌───────────┐
│    nil    │  ← not yours      │   ptr ────┼──► [ PolyNode | your fields ]
└───────────┘                   └───────────┘
                                     you own this — must transfer, recycle, or dispose
```

Two states:
- `m^ == nil` → not yours.
- `m^ != nil` → yours. You must give it away or clean it up.

### Transfer

**Before transfer:**
```
┌───────────┐
│   ptr ────┼──► [item]
└───────────┘
  m^ != nil (yours)
```

**After transfer:**
```
┌───────────┐
│    nil    │   [item] → now held by someone else
└───────────┘
  m^ == nil (not yours anymore)
```

### Receive

**Before receive:**
```
┌───────────┐
│    nil    │
└───────────┘
  m^ == nil (empty)
```

**After receive:**
```
┌───────────┐
│   ptr ────┼──► [item]   ← handed to you
└───────────┘
  m^ != nil (yours now)
```

### Two levels

- **`list.Node`** — the link. One `prev`, one `next`. If you put a node in two lists, both break.
- **`Maybe`** — the ownership flag. `nil` = not yours. Non-nil = yours.

**Honest note:** `Maybe` is a convention, not a guarantee.
Nothing stops you from copying the pointer and using it after transfer.
Odin has no borrow checker.
Matryoshka makes ownership visible.
Following it is on you.

### Ownership contract

All matryoshka APIs pass items using `^Maybe(^PolyNode)`.
This replaces separate ownership flags, reference counts, or return-value pointers.

```odin
m: Maybe(^PolyNode)

// m^ != nil  →  you own it. You must transfer, recycle, or dispose it.
// m^ == nil  →  not yours. Transfer complete, or nothing here.
// m == nil   →  nil handle. Invalid. API returns error.
```

**Entry rules:**

| `m` value | Meaning | API response |
|-----------|---------|--------------|
| `m == nil` | nil handle | error |
| `m^ == nil` | caller holds nothing | depends on API |
| `m^ != nil` | caller owns item | proceed |

**Exit rules:**

| Event | `m^` after return |
|-------|------------------|
| success (send, put) | `nil` — ownership transferred |
| success (get, receive) | `non-nil` — you own it now |
| failure | unchanged — you still own it |

---

## Builder — create and destroy by id

You have types.
You have ids.
Now you need a way to create and destroy items without knowing the type at the call site.

If you come from C++, you know ctor/dtor.
Same idea.
A pair.
Always written together.

Builder groups allocation and disposal behind two procs:

```odin
Builder :: struct {
    alloc: mem.Allocator,
    ctor:  proc(alloc: mem.Allocator, id: int) -> Maybe(^PolyNode),
    dtor:  proc(alloc: mem.Allocator, m: ^Maybe(^PolyNode)),
}
```

`ctor`:
- Allocates the correct type for `id`.
- Sets `node.id`.
- Wraps the result in `Maybe(^PolyNode)`.
- Returns nil for unknown ids.

`dtor`:
- Frees the item.
- Sets `m^ = nil`.
- Safe to call with `m == nil` or `m^ == nil` — no-op.

**Why Builder matters:**
Without Builder, you allocate manually, set the id, wrap in Maybe, and remember not to `defer free` the original pointer.
With Builder, `ctor` does all of that for you.
You call `ctor`, you get a `Maybe`.
You call `dtor`, it is gone.
No manual wrapping.
No ownership mistakes.

### Example: Builder for Event + Sensor

```odin
item_ctor :: proc(alloc: mem.Allocator, id: int) -> Maybe(^PolyNode) {
    switch ItemId(id) {
    case .Event:
        ev := new(Event, alloc)
        ev.poly.id = id
        return Maybe(^PolyNode)(&ev.poly)
    case .Sensor:
        s := new(Sensor, alloc)
        s.poly.id = id
        return Maybe(^PolyNode)(&s.poly)
    case:
        return nil
    }
}

item_dtor :: proc(alloc: mem.Allocator, m: ^Maybe(^PolyNode)) {
    if m == nil {
        return
    }
    ptr, ok := m.?
    if !ok {
        return
    }
    switch ItemId(ptr.id) {
    case .Event:
        free((^Event)(ptr), alloc)
    case .Sensor:
        free((^Sensor)(ptr), alloc)
    case:
        free(ptr, alloc)
    }
    m^ = nil
}

make_builder :: proc(alloc: mem.Allocator) -> Builder {
    return Builder{
        alloc = alloc,
        ctor  = item_ctor,
        dtor  = item_dtor,
    }
}
```

### What ctor does inside (so you don't have to)

This is the manual way — without Builder:

```odin
ev := new(Event)
ev.poly.id = int(ItemId.Event)
ev.code    = 99
m: Maybe(^PolyNode) = &ev.poly
// Maybe is the sole owner now. Do NOT defer free(ev).
```

With Builder:
```odin
m := b.ctor(b.alloc, int(ItemId.Event))
// done. Builder allocated, set id, wrapped in Maybe.
```

Builder prevents the mistakes.
You don't think about wrapping.
You don't forget to set id.
You don't accidentally `defer free` the original pointer.

### Standalone use

Builder does not need a pool.
Builder does not need a mailbox.
Any code that creates and destroys polymorphic items can use Builder directly.

Matryoshka does not need Builder either.
Builder, Master — everything described from here on — is your code.
Matryoshka gives you PolyNode, Maybe, Mailbox, Pool.
The rest is friendly advice.
Not forced. Not required.
Use it, change it, or write your own.

One exception: Pool requires hooks (PoolHooks).
But even there, the simplest Builder — just ctor and dtor wrapped into on_get/on_put — is enough.

---

## Working with lists — produce and consume

You have PolyNode.
You have Builder.
Now you move items through an intrusive list.

### Produce

Allocate items via Builder.
Push to intrusive list:

```odin
l: list.List
b := make_builder(context.allocator)

for i in 0..<3 {
    m := b.ctor(b.alloc, int(ItemId.Event))
    ptr, ok := m.?
    if !ok { continue }
    ev := (^Event)(ptr)
    ev.code = i
    ev.message = "event"
    list.push_back(&l, &ptr.node)
}
```

### Consume

Pop from list.
Dispatch on id.
Process.
Destroy via Builder:

```odin
for {
    raw := list.pop_front(&l)
    if raw == nil { break }
    poly := (^PolyNode)(raw)

    switch ItemId(poly.id) {
    case .Event:
        ev := (^Event)(poly)
        // process event
        m: Maybe(^PolyNode) = poly
        b.dtor(b.alloc, &m)
    case .Sensor:
        s := (^Sensor)(poly)
        // process sensor
        m: Maybe(^PolyNode) = poly
        b.dtor(b.alloc, &m)
    case:
        // unknown id — still clean up
        m: Maybe(^PolyNode) = poly
        b.dtor(b.alloc, &m)
    }
}
```

### What you can build with Layer 1

- Intrusive lists in one thread — no extra allocations.
- Simple game entity systems — entities live in one list at a time.
- Single-threaded pipelines — read → process → write.
- Any system where ownership changes hands instead of data being shared.

No locks. No threads yet. Just clean ownership.

---

## What you learned (Layer 1)

- Item has one owner.
- Transfer is explicit.
- Every path must end.
- Builder handles creation and destruction.
- You write the policy.
- Builder is yours. Your code, your rules. Matryoshka does not need Builder. You do.

---

# Layer 2 — Mailbox + Master

You get:
- Items that cross thread boundaries.
- A mailbox that moves ownership between Masters.
- A Master that ties it all together.

**Prerequisite:** Layer 1 (PolyNode, Maybe, Builder).

No pool yet.
Builder creates items.
Builder destroys items.
Mailbox moves them.

**Thread and Master:**
A thread is a thin container that runs exactly one Master.
You create the thread.
You pass the Master to it.
From here on, you think in Masters, not threads.

---

## Mailbox — move items between Masters

Mailbox moves `^PolyNode` from one Master to another.
Does not know your types.
Blocking, with optional timeout.
Supports interrupt and close.

Mailbox holds ownership during transit.
It releases ownership to the receiver on success.

### Types

```odin
Mailbox :: struct {
    ...............
}

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

### Init / Destroy

```odin
mbox_init    :: proc(mb: ^Mailbox)
mbox_destroy :: proc(mb: ^Mailbox)
```

---

## send — blocking, ownership transfer

```odin
mbox_send :: proc(mb: ^Mailbox, m: ^Maybe(^PolyNode)) -> SendResult
```

Entry contract:

| Entry | Contract |
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
mbox_wait_receive :: proc(mb: ^Mailbox, out: ^Maybe(^PolyNode), timeout: time.Duration = -1) -> RecvResult
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
mbox_interrupt :: proc(mb: ^Mailbox) -> IntrResult
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
Use a shared atomic or channel to communicate *what* changed.

### Receiver loop with interrupt

```odin
for {
    m: Maybe(^PolyNode)
    switch mbox_wait_receive(&mb, &m) {
    case .Ok:
        // process item
        b.dtor(b.alloc, &m)

    case .Interrupted:
        // woken without a message — check external state
        if reload_needed.load() {
            reload_config()
        }
        // next mbox_wait_receive blocks normally — flag is self-clearing

    case .Closed:
        return  // shutdown

    case .Timeout, .Already_In_Use, .Invalid:
        // handle error conditions
    }
}
```

Key points:
- `.Interrupted` delivers no message — `m` remains nil.
- The receiver must loop back to `mbox_wait_receive`.
- The interrupted flag is self-clearing — no explicit reset needed.

---

## close — orderly shutdown

```odin
mbox_close :: proc(mb: ^Mailbox) -> list.List
```

- Marks mailbox as closed.
- Further `mbox_send` returns `.Closed`.
- Wakes all Masters waiting in `mbox_wait_receive` — they return `.Closed`.
- Returns all items still in the queue as a `list.List`.
- Returns an empty list if already closed — idempotent.

**Caller must drain the returned list.**

Walk via `list.pop_front`.
Cast each `^list.Node` to `^PolyNode`.
Dispose:

```odin
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)        // safe: PolyNode at offset 0
    m: Maybe(^PolyNode) = poly
    b.dtor(b.alloc, &m)
}
```

The cast `(^PolyNode)(raw)` works because:
- Every item has `PolyNode` at offset 0 (your convention).
- `list.Node` is the first field of `PolyNode`.

Shutdown is part of normal flow.

---

## try_receive_batch — non-blocking batch drain

```odin
try_receive_batch :: proc(mb: ^Mailbox) -> list.List
```

- Non-blocking — never waits.
- Returns all currently available items as `list.List`.
- Returns empty list on: nothing available, closed, interrupted, any error.
- If mailbox is in interrupted state: clears the flag before returning.
- Without clearing, the next `mbox_wait_receive` would immediately return `.Interrupted` again.
- Caller owns all items in the returned list.

**What the list contains:**

`list.List` is a chain of `^list.Node` — intrusive links, not `^Maybe(^PolyNode)`.
Each node is a `PolyNode`.
`PolyNode` embeds `list.Node` via `using` at offset 0.
Wrap each item in `Maybe` at the processing boundary:

```odin
batch := try_receive_batch(&mb)
for {
    raw := list.pop_front(&batch)
    if raw == nil { break }
    poly := (^PolyNode)(raw)
    m: Maybe(^PolyNode) = poly
    // process item
    b.dtor(b.alloc, &m)
}
```

---

## Master — runs on a thread, owns everything

Master is a user struct.
It runs on a thread.
It is the only participant that knows concrete types.

From this point on, you think in Masters, not threads.
Master has weight. Master has responsibility.
Nothing on the stack — Master lives on the heap.

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

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.builder = make_builder(alloc)
    mbox_init(&m.inbox)
    return m
}

freeMaster :: proc(master: ^Master) {
    remaining := mbox_close(&master.inbox)
    // drain remaining items...
    mbox_destroy(&master.inbox)
    alloc := master.alloc
    free(master, alloc)
}
```

`freeMaster` owns the full teardown.
Nothing outside it should call `free` on `^Master` directly.

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

## Patterns (Layer 2)

Master runs on a thread.
From here on, you think in Masters, not threads.

No pool yet.
Builder creates items.
Builder destroys items.
Mailbox moves them between Masters.

### Request-Response

Two Masters. Two mailboxes each.
Master A sends a request.
Master B receives, processes, sends response.

```
┌─────────────┐                        ┌─────────────┐
│  Master A   │                        │  Master B   │
│             ├── mb_resp ◄════════════┤             │
│             │                        │             ├── mb_req ◄═
│             ├── mb_out  ════════════►│             │
│             │                        │             ├── mb_out
└─────────────┘                        └─────────────┘

  Master A                                Master B
  ────────                                ────────
  m := b.ctor(alloc, id)
  fill request
  mbox_send(&mb_req, &m)   ══════════►  mbox_wait_receive(&mb_req, &m)
                                         process request
                                         resp := b.ctor(alloc, resp_id)
                                         fill response
  mbox_wait_receive(&mb_resp, &m) ◄════  mbox_send(&mb_resp, &resp)
                                         b.dtor(alloc, &m)
  process response
  b.dtor(alloc, &m)
```

All items created by Builder.ctor.
All items destroyed by Builder.dtor.

### Two-mailbox interrupt + batch

Master blocks on a control mailbox.
Another Master interrupts it when data is ready on a second mailbox.
Master wakes, drains the data mailbox in batch.

```
┌─────────────┐                        ┌─────────────┐
│  Master A   │                        │  Master B   │
│             ├── mb_ctrl ◄════════════┤             │
│             │        (interrupt)     │             ├── inbox ◄═
│             ├── mb_data ◄════════════┤             │
└─────────────┘                        └─────────────┘
```

```odin
for {
    m: Maybe(^PolyNode)
    switch mbox_wait_receive(&mb_ctrl, &m) {
    case .Ok:
        // handle control message
        b.dtor(b.alloc, &m)
    case .Interrupted:
        // woken — interrupted flag already cleared by try_receive_batch
        batch := try_receive_batch(&mb_data)
        for {
            raw := list.pop_front(&batch)
            if raw == nil { break }
            poly := (^PolyNode)(raw)
            m2: Maybe(^PolyNode) = poly
            // process data item
            b.dtor(b.alloc, &m2)
        }
    case .Closed:
        return
    }
}
```

### Pipeline

Chain of Masters.
Each Master: receive → process → send forward.

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│  Master A   │         │  Master B   │         │  Master C   │
│             ├── out ══┤             │         │             │
│             │    ════►│             ├── out ══┤             │
│             ├── in ◄═ │             │    ════►│             ├── in ◄═
└─────────────┘         │             ├── in ◄═ └─────────────┘
                        └─────────────┘

  Master A:
      m := b.ctor(alloc, id)
      fill data
      mbox_send(&mb1, &m)

  Master B:
      mbox_wait_receive(&mb1, &m)
      process
      mbox_send(&mb2, &m)   // forward — no destroy, ownership transfers

  Master C:
      mbox_wait_receive(&mb2, &m)
      consume
      b.dtor(alloc, &m)     // final consumer destroys
```

### Fan-In

Multiple Masters send to one mailbox.
One Master receives.

```
┌──────────┐
│Master A  ├── out ═══╗
│          ├── in  ◄═ ║    ┌──────────┐
└──────────┘          ╠═══►│ Receiver │
┌──────────┐          ║    │          ├── inbox ◄═
│Master B  ├── out ═══╣    └──────────┘
│          ├── in  ◄═ ║
└──────────┘          ║
┌──────────┐          ║
│Master C  ├── out ═══╝
│          ├── in  ◄═
└──────────┘
```

Receiver dispatches on id:

```odin
for {
    m: Maybe(^PolyNode)
    switch mbox_wait_receive(&mb, &m) {
    case .Ok:
        ptr, ok := m.?
        if !ok { continue }
        switch ItemId(ptr.id) {
        case .Event:
            // process event
        case .Sensor:
            // process sensor
        }
        b.dtor(b.alloc, &m)
    case .Closed:
        return
    }
}
```

### Fan-Out

One Master sends.
Multiple worker Masters receive from the same mailbox.
Whichever worker is free picks up the next item.

```
                      ┌──────────┐
                 ╔════│Worker A  │
                 ║    │          ├── inbox ◄═
┌──────────┐     ║    └──────────┘
│ Master A ├── out    ┌──────────┐
│          │  ════►═══│Worker B  │
│          ├── in ◄═  │          ├── inbox ◄═
└──────────┘     ║    └──────────┘
                 ║    ┌──────────┐
                 ╚════│Worker C  │
                      │          ├── inbox ◄═
                      └──────────┘

All workers call mbox_wait_receive on the same mailbox.
One wakes. The others keep waiting.
```

No round-robin. No routing logic. The mailbox does the distribution.

### Shutdown — Exit message

Don't think in threads.
Don't use thread.join.
Master sends an Exit message to another Master's mailbox.
That Master receives it and returns from its loop.

```
┌─────────────┐                        ┌─────────────┐
│ MainMaster  │                        │  Worker     │
│             ├── out  ════════════════►│             │
│             │  (Exit message)        │             ├── inbox ◄═
│             ├── inbox ◄═             │             │
└─────────────┘                        └─────────────┘
```

```odin
// MainMaster sends Exit
ExitId :: enum int { Exit = 99 }

m := b.ctor(b.alloc, int(ExitId.Exit))
mbox_send(&worker.inbox, &m)

// Worker receives
for {
    m: Maybe(^PolyNode)
    switch mbox_wait_receive(&worker.inbox, &m) {
    case .Ok:
        ptr, ok := m.?
        if !ok { continue }
        if ptr.id == int(ExitId.Exit) {
            b.dtor(b.alloc, &m)
            return  // Master returns from its loop — done
        }
        // handle other messages
        b.dtor(b.alloc, &m)
    case .Closed:
        return
    }
}
```

---

### What you can build with Layer 1 + 2

- Multi-threaded pipelines — read → process → write across Masters.
- Request-response pairs — Master A asks, Master B answers.
- Worker pools — fan-out to multiple worker Masters, fan-in results.
- Background processing — one Master compresses, another writes.
- Any system where items travel between threads and every item has one owner.

Builder creates. Builder destroys. Mailbox moves. No pool yet.

## What you learned (Layer 2)

- Absence is also a state — timeout, interrupt.
- Not every signal carries data.
- Shutdown is part of normal flow.
- Think in Masters, not threads.
- Master sends Exit, not thread.join.
- Builder handles the lifecycle — no pool needed yet.
- You make mistakes.
- You send twice. You forget to clean up. You use wrong id.
- It fails. Not silently. You see it. You fix it.
- Master is yours. Your code, your logic. Matryoshka gives you Mailbox. Master is what you build on top.

---

# Layer 3 — Pool + Recycler

You get:
- Items that come back.
- Reuse without re-allocation.
- Policy hooks for flow control.

**Prerequisite:** Layer 1 + Layer 2.

At some point allocations hurt.
Not always.
Only under pressure.

You add Pool.

First version is simple.
It works.

Then:
- too many items
- or not enough

You add limits.
You start to decide: keep or drop.

Reuse is not free.
It needs policy.

---

## THE FIRST RULE OF POOL

You don't know pool yet.
You haven't seen the APIs.
Read this first.
Remember it.

Pool has many conditions, results, and rules.
That is not a bug — it is the point.
Pool tries to catch wrong combinations early — before they become silent failures.
Pool is strong. Pool saves lives. *(We are serious about the first part.)*

**The rule:** check the result of every API call.
The table below tells you what "ok" looks like for each one.
If it is not ok — fix the root cause.
Do not retry the same mistake.

| API | Returns | "Ok" means |
|-----|---------|------------|
| `pool_init` | nothing | no panic — bad input panics immediately |
| `pool_get` | `Pool_Get_Result` | `.Ok` and `m^` is non-nil |
| `pool_get_wait` | `Pool_Get_Result` | `.Ok` and `m^` is non-nil |
| `pool_put` | nothing | `m^` is `nil` after the call — pool took it |
| `pool_close` | `(list.List, ^PoolHooks)` | always succeeds — drain the returned list |

For `pool_put`: if `m^` is still non-nil after the call, the pool is closed.
You own the item.
Dispose manually.

For `pool_get` / `pool_get_wait`: any result other than `.Ok` has a specific meaning.
See the result table below.

---

## Recycler — your hooks for the pool

You already have Builder from Layer 1.
Builder creates and destroys by id.

Recycler extends that idea.
Recycler adds:
- **Reuse** — reinitialize instead of destroy + create.
- **Policy** — decide whether to keep or drop.
- **Counts** — `in_pool_count` tells how many items are idle.
- **Context** — `ctx` carries your state.
- **Registration** — `ids` declares which item types this pool handles.

```
Builder (Layer 1):   ctor + dtor + alloc
Recycler (Layer 3):  on_get + on_put + ctx + ids
```

### PoolHooks

```odin
PoolHooks :: struct {
    ctx:    rawptr,         // user context — carries master or any state
                            // may be nil — pool passes it as-is
    ids:    [dynamic]int,   // user-owned; non-empty, all != 0; user deletes in freeMaster
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}
```

Two procs only.
Both communicate through `m`.
Both are required.

`ctx` may be nil.
Pool passes it as-is.
Hook must handle nil `ctx` safely.

`ids` is a `[dynamic]int` owned by the user:
- Populate with `append` before calling `pool_init`.
- Delete in `freeMaster` before `free(master, alloc)`.

**`ctx` is runtime** — cannot be set in a `::` compile-time constant.
Set it before calling `pool_init`.

### on_get contract

Pool calls `on_get` on every `pool_get`.
Exception: `Available_Only` when no item is stored.

Pool passes `m^` as-is.
Hook decides what to do.

| Entry state | Meaning | Hook must |
|-------------|---------|-----------|
| `m^ == nil` | no item available | create a new item, set `node.id = id`, set `m^` |
| `m^ != nil` | recycled item | reinitialize for reuse |

`in_pool_count`: number of items with this `id` currently idle in the pool.
Not total live objects.
Hook may use it to decide whether to create or not.

After `on_get`:

| Exit state | Meaning |
|------------|---------|
| `m^ != nil` | item ready — pool returns `.Ok` to caller |
| `m^ == nil` | pool returns `.Not_Created` to caller |

`.Not_Created` is not always an error.
Hook may return nil on purpose.

`id` is always passed.
Needed for creation.
Can also be read from `node.id` on recycle — but passing it avoids the cast.

### on_put contract

Called during `pool_put`, outside lock.

`in_pool_count`: current count of items with this id currently idle in the pool.
Not total live objects.
Use it to decide flow control.

After `on_put`:

| Exit state | Meaning |
|------------|---------|
| `m^ == nil` | hook disposed it — pool discards |
| `m^ != nil` | pool stores it |

### Hook rules

- All hooks are called **outside the pool mutex** — guaranteed.
- Hooks may safely take their own locks without deadlock risk.
- Hooks must NOT call `pool_get` or `pool_put` — that re-enters the pool and deadlocks.
- Allocator stored in `ctx` must be thread-safe.
- `ctx` must outlive the pool.

### Hook examples

```odin
master_on_get :: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    master := (^Master)(ctx)
    if m^ == nil {
        // no item available — create new one using master.alloc
        switch FlowId(id) {
        case .Chunk:
            c := new(Chunk, master.alloc)
            c.id = id
            m^ = (^PolyNode)(c)
        case .Progress:
            p := new(Progress, master.alloc)
            p.id = id
            m^ = (^PolyNode)(p)
        }
    } else {
        // recycled item — reinitialize using master fields
        node := m^
        switch FlowId(node.id) {
        case .Chunk:    (^Chunk)(node).len = 0
        case .Progress: (^Progress)(node).percent = 0
        }
    }
}

master_on_put :: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)) {
    master := (^Master)(ctx)
    if m == nil || m^ == nil { return }
    node := m^
    #partial switch FlowId(node.id) {
    case .Chunk:
        if in_pool_count > 400 {
            free((^Chunk)(node), master.alloc)
            m^ = nil  // dispose — pool will not store
        }
    case .Progress:
        if in_pool_count > 128 {
            free((^Progress)(node), master.alloc)
            m^ = nil  // dispose — pool will not store
        }
    }
    // m^ still non-nil here → pool stores it
}
```

### Standalone use

Recycler without Pool is valid.
It is Builder with policy.
User calls `on_get` and `on_put` directly.
User decides keep or drop without pool storage.

---

## Pool API

Pool holds reusable items.
Works with `^PolyNode` only.
Does not know your types.
Pool is just storage.
All lifecycle decisions live in `PoolHooks`.

### Types

```odin
Pool :: struct {
    ...............
}

Pool_Get_Mode :: enum {
    Available_Or_New,  // existing item if available, otherwise create
    New_Only,          // always create
    Available_Only,    // existing item only — no creation, on_get not called if none stored
}

Pool_Get_Result :: enum {
    Ok,             // item returned in m^
    Not_Available,  // Available_Only: no item stored — on_get was not called
    Not_Created,    // on_get ran and returned nil — may be deliberate or failure
    Closed,         // pool is closed
    Already_In_Use, // m^ != nil on entry — caller holds an unreleased item
}
```

### Init / Close

```odin
pool_init  :: proc(p: ^Pool, hooks: ^PoolHooks)
pool_close :: proc(p: ^Pool) -> (list.List, ^PoolHooks)
```

`pool_init`:
- Takes `^PoolHooks`.
- Pool stores the pointer.
- User keeps the struct.

`pool_close` contract:

```odin
nodes, h := pool_close(&p)
```

- Returns all items currently stored in the pool as `list.List`.
- Returns `^PoolHooks` — the pointer passed to `pool_init`.
- Pool zeros its internal hooks pointer on close.
- Post-close `pool_get`/`pool_put` return `.Closed` or no-op.
- Pool does not call `on_put` during close. User drains manually.

### get — acquire ownership

```odin
pool_get :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, m: ^Maybe(^PolyNode)) -> Pool_Get_Result
```

| Mode | Behavior |
|------|----------|
| `.Available_Or_New` | check free-list; call `on_get` on hit or miss |
| `.New_Only` | always call `on_get` with `m^==nil`; skip free-list |
| `.Available_Only` | free-list only; return `.Not_Available` if empty — `on_get` not called |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `m^` set to item |
| `.Not_Available` | `.Available_Only` and no item stored |
| `.Not_Created` | `on_get` ran and returned nil |
| `.Closed` | pool is closed |
| `.Already_In_Use` | `m^` was non-nil on entry — release current item first |

#### Validation order

Both `pool_get` and `pool_get_wait` apply the same entry checks:

| Priority | Check | Result |
|----------|-------|--------|
| 1 | `id == 0` | **panic** — zero id is always a programming error |
| 2 | `m^ != nil` | `.Already_In_Use` — caller holds an unreleased item |
| 3 | pool closed | `.Closed` |
| 4 | `id` not in registered set (open pool only) | **panic** — foreign id is a programming error |
| 5 | proceed with get logic | — |

### get_wait — block until item available

```odin
pool_get_wait :: proc(p: ^Pool, id: int, m: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

Equivalent to `pool_get(.Available_Only)` but with blocking.
Never calls `on_get` — only waits for an item to be stored.

`pool_get_wait` with timeout = 0 is the same as `pool_get` with `Available_Only`.

| `timeout` | Behavior |
|-----------|----------|
| `== 0` | non-blocking — returns `.Not_Available` immediately if no item stored |
| `< 0` | blocks forever — waits until an item is put back or pool is closed |
| `> 0` | blocks up to the duration — returns `.Not_Available` on expiry |

| Result | Meaning |
|--------|---------|
| `.Ok` | item acquired — `m^` set to item |
| `.Not_Available` | no item stored (non-blocking or timeout expired) |
| `.Closed` | pool is closed, or closed while waiting |

### put — return to pool

```odin
pool_put :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Algorithm — in this order:

1. Check `m.?.id`:
   - `id == 0` → **PANIC** (zero is always invalid)
   - `id not in ids[]` → **PANIC** (not registered — programming error)
     > **Implementation note:** Odin's `in` operator does not work on `[dynamic]int`. Use `slice.contains(hooks.ids[:], id)`.
2. Get `in_pool_count` for this id (under lock, then unlock)
3. Call `hooks.on_put(ctx, in_pool_count, m)` — **outside lock**
4. If `m^` is still non-nil → push to free-list, increment count, set `m^ = nil` (under lock)

Open pool → `on_put` decides: hook sets `m^=nil` (disposed) or leaves `m^!=nil` (stored).

> **Closed pool + valid id:** `pool_put` returns with `m^` still non-nil. Caller owns the item.
> Must dispose manually. Does not panic.

### defer pool_put — when is it safe?

`pool_put` with `m^ == nil` is always a no-op.
No id check. No panic.

This means `defer pool_put` can be placed immediately after `m: Maybe(^PolyNode)`, before `pool_get`:

```odin
m: Maybe(^PolyNode)
defer pool_put(&p, &m)  // [itc: defer-put-early] — safe: pool_put is no-op when m^ == nil
if pool_get(&p, id, .Available_Or_New, &m) != .Ok {
    return
}
// ... work ...
```

Three outcomes when `defer pool_put` fires:
- `m^ == nil` (pool_get failed, or item was transferred) → `pool_put` is a no-op.
- `m^ != nil` (item was not transferred) → `pool_put` recycles or `on_put` disposes.
- `m^ != nil` with unknown id or zero id → `pool_put` panics — programming error.

Safe for valid ids.
The panic is the correct behavior — it tells you exactly where the bug is.

> `[itc: defer-put-early]` — candidate for `design/sync/new-idioms.md`.

### put_all — return a chain

```odin
pool_put_all :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
```

Walks the linked list starting at `m^`, calling `pool_put` on each node.
Panics on zero or unknown id in any node.

---

## ID System

### Rules

You are not going to memorize these rules.
But when you write your own Builder or Recycler, you will come back here.

- Every item id must be != 0. Zero is reserved/invalid.
- `pool_init` reads valid ids from `hooks.ids`.
- User populates with `append` before calling `pool_init`.
- `pool_put` panics on `id == 0` (open or closed).
- `pool_put` panics on unknown id only when the pool is **open**.
- Post-close the pool holds no hooks and cannot validate ids.
- Unknown id with closed pool leaves `m^` non-nil.
- `on_get` sets `node.id` at allocation time.
- Id values are user-defined integer constants — typically from an enum.

### Why panic on unknown id?

A foreign id on `pool_put` is almost always a bug:
- wrong cast earlier
- wrong pool
- memory corruption
- use-after-free

Silent recycling would create silent starvation or use-after-free later.
A loud panic during development is far cheaper than hunting ghosts in production.

Zero is always invalid because it is the zero value of `int`.
An uninitialized `PolyNode` would have `id == 0`.
Panicking on zero catches missing initialization immediately.

### Example

```odin
FlowId :: enum int {
    Chunk    = 1,  // must be != 0
    Progress = 2,
}

// Registration: populate hooks.ids before pool_init
append(&hooks.ids, int(FlowId.Chunk))
append(&hooks.ids, int(FlowId.Progress))
pool_init(&p, &hooks)
```

---

## Master with Pool — extending Layer 2's Master

In Layer 2, Master held Builder and mailbox references.
Now Master holds Pool and Recycler (PoolHooks) too.

Builder from Layer 1 becomes the basis for your hooks.
The same creation and destruction logic lives in `on_get` and `on_put`.

```odin
Master :: struct {
    pool:  Pool,
    hooks: PoolHooks,
    inbox: Mailbox,
    alloc: mem.Allocator,
    // ... other state ...
}

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.hooks = PoolHooks{
        ctx    = m,
        on_get = master_on_get,
        on_put = master_on_put,
    }
    append(&m.hooks.ids, int(FlowId.Chunk))
    append(&m.hooks.ids, int(FlowId.Progress))
    pool_init(&m.pool, &m.hooks)
    mbox_init(&m.inbox)
    return m
}

freeMaster :: proc(master: ^Master) {
    // 1. close pool — get back stored items
    nodes, _ := pool_close(&master.pool)

    // 2. drain and dispose all returned items
    // NOTE: dispose nodes before freeing other Master resources.
    for {
        raw := list.pop_front(&nodes)
        if raw == nil { break }
        // dispose node — master knows how
    }

    // 3. close and drain mailbox
    remaining := mbox_close(&master.inbox)
    // drain remaining...
    mbox_destroy(&master.inbox)

    // 4. delete ids dynamic array (user-owned)
    delete(master.hooks.ids)

    // 5. free Master last — save alloc first
    alloc := master.alloc
    free(master, alloc)
}
```

Pool borrows hooks — pointer, not copy.
`freeMaster` owns the full teardown.

---

## Pre-allocating (Seeding the Pool)

To avoid runtime latency, pre-allocate before starting Masters:

```odin
master := newMaster(context.allocator)

for _ in 0..<100 {
    m: Maybe(^PolyNode)
    if pool_get(&master.pool, int(FlowId.Chunk), .New_Only, &m) == .Ok {
        pool_put(&master.pool, &m)  // put back immediately — goes to free-list
    }
}
```

`New_Only` always calls `on_get` with `m^==nil`, forcing creation even when items are stored.

---

## Pool Get Modes

Mode is a per-call parameter of `pool_get`.
Not a pool-wide setting.

```odin
// Normal operation — use stored item if available, create if not
pool_get(&master.pool, int(FlowId.Chunk), .Available_Or_New, &m)

// Force creation — use for seeding or when you want a guaranteed fresh item
pool_get(&master.pool, int(FlowId.Chunk), .New_Only, &m)

// Stored only — use in no-alloc paths
// Returns .Not_Available if no item stored — on_get not called
if pool_get(&master.pool, int(FlowId.Chunk), .Available_Only, &m) != .Ok {
    // no item stored — handle: skip, back off, or call pool_get_wait
}
```

---

## Patterns (Layer 3)

### Builder to Pool — simplest upgrade from Layer 2

Replace Builder.ctor/dtor calls with pool_get/pool_put.
Same patterns, now with recycling.

Layer 2 sender:
```odin
m := b.ctor(b.alloc, int(FlowId.Chunk))
// fill
mbox_send(&mb, &m)
```

Layer 3 sender:
```odin
m: Maybe(^PolyNode)
defer pool_put(&p, &m)  // [itc: defer-put-early]
if pool_get(&p, int(FlowId.Chunk), .Available_Or_New, &m) != .Ok {
    return
}
// fill
mbox_send(&mb, &m)
// m^ is nil after send — defer pool_put is a no-op
```

### Backpressure

`on_put` checks `in_pool_count`.
Too many idle items → dispose.

```odin
// in master_on_put:
if in_pool_count > 400 {
    free((^Chunk)(node), master.alloc)
    m^ = nil  // dispose — pool will not store
}
```

Start simple.
Add limits when it hurts.

### Pre-allocation

See "Pre-allocating (Seeding the Pool)" above.

### Full lifecycle with mailbox

```
┌─────────────┐                        ┌─────────────┐
│Sender Master│                        │Recv Master  │
│             ├── pool                 │             ├── pool
│             ├── out  ════════════════►│             │
│             │                        │             ├── inbox ◄═
│             ├── inbox ◄═             │             │
└─────────────┘                        └─────────────┘
```

**Setup:**
```odin
FlowId :: enum int { Chunk = 1, Progress = 2 }

master := newMaster(context.allocator)
defer freeMaster(master)
```

**Sender Master:**
```odin
m: Maybe(^PolyNode)
defer pool_put(&master.pool, &m)  // [itc: defer-put-early]

if pool_get(&master.pool, int(FlowId.Chunk), .Available_Or_New, &m) != .Ok {
    return
}

// fill
ptr, ok := m.?
if !ok { return }
c := (^Chunk)(ptr)
c.len = fill(c.data[:])

// transfer
if mbox_send(&mb, &m) != .Ok {
    return  // send failed — defer pool_put recycles
}
// m^ is nil — transfer done — defer pool_put is a no-op
```

**Receiver Master:**
```odin
m: Maybe(^PolyNode)
defer pool_put(&master.pool, &m)  // safety net

if mbox_wait_receive(&mb, &m) != .Ok {
    return
}

ptr, ok := m.?
if !ok { return }

switch FlowId(ptr.id) {
case .Chunk:
    c := (^Chunk)(ptr)
    process_chunk(c)
    pool_put(&master.pool, &m)    // explicit return — defer is no-op

case .Progress:
    pr := (^Progress)(ptr)
    update_progress(pr)
    pool_put(&master.pool, &m)    // explicit return — defer is no-op
}
```

**Why both `defer pool_put` and per-case `pool_put`?**

- Per-case `pool_put` is the normal path — it sets `m^ = nil`.
- After that, the deferred `pool_put` fires and sees `m^ == nil` — becomes a no-op.
- The `defer` is a safety net for paths you did not anticipate.
- Belt and suspenders — intentional.

**Shutdown:**
```odin
remaining := mbox_close(&mb)

for {
    raw := list.pop_front(&remaining)
    if raw == nil { break }
    poly := (^PolyNode)(raw)
    m: Maybe(^PolyNode) = poly
    pool_put(&master.pool, &m)
    if m^ != nil {
        // pool was already closed — dispose manually
    }
}

freeMaster(master)
```

---

### What you can build with all three layers

- Compression pipeline — chunks flow from reader Master to worker Masters and back, recycled through Pool.
- Game engine — entities, bullets, particles allocated from Pool, dispatched across Masters, recycled on death.
- Network server — request buffers from Pool, dispatched to handler Masters, response buffers returned to Pool.
- Streaming processor — data flows through a chain of Masters, Pool absorbs allocation spikes.

Same vocabulary at every level: get → fill → send → receive → put back.
Only the hooks grow when you need control.

## What you learned (Layer 3)

- Reuse is not free — it needs policy.
- Pool is strong. Check every result.
- Your hooks grow when you need control.
- Pool code never changes. Only your hooks become smarter.
- You look back at your first code. You don't like it.
- You rewrite it. Nothing forces you to keep it.
- You keep only what you learned.
- Recycler is yours. Your hooks, your policy. Pool never changes. Your hooks grow.

---

# Rules

You are not going to memorize this table.
But when something breaks, you will come back here.

| # | Rule | Consequence of violation |
|---|------|--------------------------|
| R1 | `m^` is the ownership bit. Non-nil = you own it. | Double-free or leak. |
| R2 | All callbacks called outside pool mutex. | Guaranteed by pool. User may hold their own locks inside callbacks. |
| R3 | `on_get` is called on every `pool_get` except `Available_Only` when no item stored. | Hook handles both create (`m^==nil`) and reinitialize (`m^!=nil`). |
| R4 | Pool maintains per-id `in_pool_count`. Passed to `on_get` and `on_put`. | Enables flow control. |
| R5 | `id == 0` on `pool_put` or `mbox_send` → immediate panic or `.Invalid`. | Programming errors surface immediately. |
| R6 | Unknown id on `pool_put` → **panic** if pool is open. Closed pool: `m^` stays non-nil — caller owns the item. | Panics catch bugs early; closed pool returns ownership cleanly. |
| R7 | `on_put`: if `m^ != nil` after hook → pool stores it. If `m^ == nil` → pool discards. | Hook sets `m^ = nil` to dispose. |
| R8 | Always use `ptr, ok := m.?` to read the inner value of `Maybe(^PolyNode)`. Never use the single-value form `ptr := m.?`. | Single-value form panics if nil. |
| R9 | `ctx` must outlive the pool. Do not tie `ctx` to a stack object or any resource freed before `pool_close`. | Hook called after `ctx` freed → use-after-free. |

---

# What matryoshka owns vs what you own

## Matryoshka owns

- `PolyNode` shape — `node` + `id`.
- `^Maybe(^PolyNode)` ownership contract across all APIs.
- Pool modes per `pool_get` call.
- Hook dispatch — `on_get` / `on_put` called with `ctx`.
- Guarantee: hooks called outside pool mutex.
- `pool_put` — sets `m^ = nil` after return, or panics on zero id.
- Panics on unknown id only when open.
- `mbox_close` — returns remaining chain as `list.List`. Caller must drain.

## You own

- Id enum definition.
- Builder (Layer 1). Your code, your rules.
- Master (Layer 2). Your code, your logic.
- All `PoolHooks` hook implementations (Layer 3). Your hooks, your policy.
- Locking inside hooks — pool makes no constraints on hook internals.
- Per-id count limits — expressed in `on_put`.
- Byte-level limits — maintain a counter in `ctx`, dispose in `on_put` when over limit.
- Receiver switch logic and casts.
- Returning every item — via `pool_put`, `mbox_send`, or `b.dtor`. Disposing manually after close.

---

# Addendums

These are real conversations between the Author and AI.

---

## `^Maybe(^PolyNode)` vs `^^PolyNode`

**Author:** I designed how to use `^Maybe(^PolyNode)` for matryoshka, but I still don't fully understand why it has to be this way. Can't I just use `^^PolyNode`? It's simpler. Two pointers. Why do I need `Maybe` at all? Explain it to me.

**AI:** They are not equivalent. `^^PolyNode` is a pointer to a pointer. It gives you two nil states:

- `m == nil` — the handle itself is nil.
- `*m == nil` — the inner pointer is null.

But it has no unwrap operator. No "valid or not" semantics built into the type.

`Maybe(T)` in Odin is a tagged union: `union { T, nil }`. It adds the `.?` operator and one extra semantic state:

| Expression | `^Maybe(^PolyNode)` | `^^PolyNode` |
|------------|---------------------|--------------|
| `m == nil` | nil handle — programming error | same |
| `m^ == nil` | you do NOT own the item | same (but ambiguous — was it transferred? freed? never set?) |
| `m^ != nil` | you own it | same |
| `ptr, ok := m.?` | safe unwrap | not available |
| `m^ = nil` after send | unambiguous: ownership transferred | ambiguous: could mean anything |

The critical difference is the transfer signal. With `^^PolyNode`, setting `*m = nil` just means the inner pointer is null. Nothing more. It cannot tell the caller whether the item was transferred, freed, never allocated, or hit an error condition.

With `^Maybe(^PolyNode)`, `m^ = nil` is the ownership transfer rule:
- API sets it on success → "I took it, you no longer own it."
- API leaves it on failure → "Still yours, I didn't take it."
- Caller checks it to know whether to free on exit.

This is why `defer pool_put(&p, &m)` works:
`pool_put` checks `m^ == nil` → no-op if already transferred.
With `^^PolyNode`, you cannot make that check reliably.

**Author:** OK, too much. What about three nil levels?

**AI:** Right, simpler:

```
m == nil      → nil handle        → programming error, return .Invalid
m^ == nil     → inner is nil      → don't own it (transferred or nothing)
m^ != nil     → inner is non-nil  → you own it
```

`^^PolyNode` only has two of these levels.
The difference between "transferred" and "never had it" disappears.

**Author:** So Maybe carries the ownership bit for free. And `.?` is the safe way to read it.

**AI:** Exactly. `Maybe` puts the ownership contract into the type:
- nil inner = not yours.
- non-nil inner = yours.
- `.?` = safe check-and-extract in one step.

`^^PolyNode` is just a raw double pointer with no ownership meaning.

**Author:** Keep `^Maybe(^PolyNode)`.

---

## The `.?` unwrap operator

**Author:** I keep seeing `.?` in the code. Two forms. Which one do I use?

**AI:** `Maybe(T)` in Odin is a tagged union: `union { T, nil }`. `.?` is the unwrap operator.

Two-value form — **use this**:

```odin
ptr, ok := m.?
```

Safe. No panic. `ok` is `false` if `m == nil`. `ptr` is only valid when `ok` is `true`.

Single-value form — **big no-no**:

```odin
ptr := m.?
```

Returns the inner value directly. **Panics at runtime if `m == nil`.** In concurrent code a panic here means a crash with no recovery.

**Author:** So always two-value form. Got it.

**AI:** Yes. Here's the summary:

| Form | Rule |
|------|------|
| `ptr, ok := m.?` | always use this — check and extract in one step |
| `ptr := m.?` | big no-no — panics if nil |
| `^^PolyNode` | neither form available — raw dereference only |

**Author:** Do not use the single-value form in matryoshka code.

---

> ***Author's note.*** *This dialog never was. I never was fully sure about `^Maybe(^PolyNode)`. Still not sure. But it's right.*
