# Layer 2 — Mailbox + Master — Deep Dive

> See [Quick Reference](layer2_quickref.md) for API signatures and contracts.
>
> **Prerequisite:** [Layer 1](layer1_quickref.md) (PolyNode, Maybe, Builder).

---

## Receiver loop with interrupt

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

## Close — drain example

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

## try_receive_batch — processing example

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

## Master — full example

```odin
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

---

## Patterns

Master runs on a thread.
From here on, you think in Masters, not threads.

No pool yet.
Builder creates items.
Builder destroys items.
Mailbox moves them between Masters.

---

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

---

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

---

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

---

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

---

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

---

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

## What you can build with Layer 1 + 2

- Multi-threaded pipelines — read → process → write across Masters.
- Request-response pairs — Master A asks, Master B answers.
- Worker pools — fan-out to multiple worker Masters, fan-in results.
- Background processing — one Master compresses, another writes.
- Any system where items travel between threads and every item has one owner.

Builder creates. Builder destroys. Mailbox moves. No pool yet.
