# Micro-System: Mini Print Server

**Discovery document — planning only. No code. No stage.**

---

## 1. Intent

The idioms in `design/idioms.md` exist because real protocols demand them. This document shows *why* each idiom is necessary by tracing it back to a concrete design conversation.

The starting point is the **tofu mantra** (`github.com/g41797/tofu`): a short dialog between two developers designing a message protocol for a Print Server. The mantra's claim:

> "Connect your developers. Then connect your applications."

Design the communication contract through conversation before writing code.

The same dialog applies directly to matryoshka. The two developers are designing the protocol between two matryoshka Masters. The messages they discuss are **items from pools**. The channels are **mboxes**. The Worker instances on R's side are **items in a thread pool**.

A reader of this document sees the design conversation first — then sees each idiom appear because the protocol demanded it.

---

## 2. The developer dialog (matryoshka version)

**Context:**

- Two developers are designing the message flow for a new Print Server.
- **S** is the Spool Server developer. S builds the Master that accepts print jobs and dispatches them.
- **R** is the Worker developer. R builds the Worker side that processes PDL data.
- Each "message" in the dialog is an **item from a pool**. Each "channel" is an **mbox**.

---

```
S: I don't know the addresses of the workers, so you should connect to me.
   Your Worker Master will send items to my forward mbox.

R: I'll get a HelloRequest item from my pool and send it. The item will carry
   a PDL-type field — either PS or PDF — so you know what I can process.

S: Do I need to send you a HelloResponse item?

R: No. Just start sending me job items on the forward mbox. I'll start
   processing as soon as I receive the first one.

S: The first item will carry a plain header — job ID and ticket type.
   The following items will carry PDL data. The PDL data can be large —
   it will be a string field inside the item.

R: Then those items are disposable. I'll get them from a disposable-item pool.
   The pool handles reset and dispose automatically via T_Hooks.

S: You forgot the Job Ticket.

R: Right. The first item should have a JobTicket field — JDF or PPD — and the
   ticket data as a string. The following items will have the PDL field with
   the content.

S: But JDF is usually used only for PDF...

R: Yes, but let's keep it flexible.

S: Can you process several jobs simultaneously?

R: It depends on licensing. Anyway, if I can, I'll borrow another Worker item
   from the thread pool. One job per Worker keeps things clean.

S: I need a progress signal.

R: No problem. I'll get a ProgressSignal item from my pool and send it back
   on the return mbox. The item will carry the job ID and the page range [N:M].

S: On job finish, send me a Response item with the job ID and processing status.

R: Why send an obsolete item? Are you expecting a graceful close?

S: Of course.

R: Then I'll send a ByeRequest item on the return mbox. The item will carry
   the same information. You'll send me a ByeResponse item on the forward mbox.
   After that my Worker Master will drain and exit.

S: That's enough for today. I'll save the item-type list in Git.

R: Deal. How about a cup of coffee?
```

---

## 3. Item type inventory

| Name | Plain / Disposable | Key fields | Direction | Pool owner |
|---|---|---|---|---|
| `HelloRequest` | Plain | `pdl_type: PDL_Type` | R → S (via forward mbox) | Worker Master |
| `JobTicket` | Disposable | `job_id: int`, `ticket_type: Ticket_Type`, `ticket_data: string` | S → R (via forward mbox) | Spool Master |
| `PDLChunk` | Disposable | `job_id: int`, `pdl_type: PDL_Type`, `content: string` | S → R (via forward mbox) | Spool Master |
| `ProgressSignal` | Plain | `job_id: int`, `page_from: int`, `page_to: int` | R → S (via return mbox) | Worker Master |
| `ByeRequest` | Plain | `job_id: int`, `status: Job_Status` | R → S (via return mbox) | Worker Master |
| `ByeResponse` | Plain | `job_id: int` | S → R (via forward mbox) | Spool Master |

**Notes:**

- `JobTicket` and `PDLChunk` carry a `string` field — dynamic heap resource. They require `dispose`, `reset`, and `factory` registered in `T_Hooks`. These are **disposable items**.
- All other items carry only value-type fields. `free` destroys them completely. These are **plain items**.
- `HelloRequest` travels in the initial handshake only. After that the forward mbox carries job items exclusively.

---

## 4. Mbox topology

```
Spool Master                        Worker Master
     │                                   │
     │  ←── HelloRequest ─────────────── │
     │                                   │
     │  ──── JobTicket ──────────────→   │
     │  ──── PDLChunk (×N) ──────────→  │
     │                                   │
     │  ←── ProgressSignal (×M) ──────── │
     │                                   │
     │  ←── ByeRequest ────────────────  │
     │  ──── ByeResponse ────────────→   │
     │                                   │
     ╔═══════════════╗         ╔═══════════════════╗
     ║  forward mbox ║         ║   return mbox     ║
     ║  S→R          ║         ║   R→S             ║
     ╚═══════════════╝         ╚═══════════════════╝
```

- **Forward mbox** (owned by Spool Master): carries `HelloRequest` (first), then `JobTicket`, `PDLChunk`, `ByeResponse`.
- **Return mbox** (owned by Worker Master): carries `ProgressSignal`, `ByeRequest`.
- Mboxes move **ownership**. Sender's `Maybe(^Itm)` inner becomes nil on successful send.

### Fan-Out

One sender, multiple receivers all reading from the same mbox.
Each item goes to whichever receiver calls `mbox.recv` first.
Result: natural load balancing across N workers.

```
[Spool Master] ──→ [mbox] ──→ [Worker A]
                         ──→ [Worker B]
                         ──→ [Worker C]
```

### Fan-In

Multiple senders, one receiver reading from one mbox.
Items from all senders arrive in arrival order.
Result: aggregation / merge point.

```
[RIP Master]          ──→ \
[Image Master]        ──→  [mbox] ──→ [Output Master]
[Color Profile Master]──→ /
```

No special framework code for either pattern. Just mbox + N Masters.

---

## 5. Internal architecture

### Spool Master

The Spool Master is the coordinator. It:

- Owns the **forward mbox** (receives from Workers; sends job items to Workers).
- Owns pools for `JobTicket`, `PDLChunk`, `ByeResponse` (plain).
- Holds a reference to the **Worker pool** (borrows and returns Worker Masters).
- On each new connection: borrows a Worker item from the thread pool, sends `HelloRequest`, then sends job items.
- On graceful close: receives `ByeRequest`, sends `ByeResponse`, returns Worker item to pool.
- Is heap-allocated. Threads hold `^SpoolMaster` safely.

### Worker side

The Worker side uses the **pool-of-threads** pattern:

```
Worker :: struct {
    thread:  ^thread.Thread,
    inbox:   mbox.Mbox,    // receives job items from Spool Master
    outbox:  mbox.Mbox,    // sends progress + bye back to Spool Master
}
WORKER_HOOKS :: pool.T_Hooks(Worker){
    factory = worker_factory,   // spawn thread, init mboxes
    dispose = worker_dispose,   // close mboxes, join thread, free
}
```

- The Spool Master owns the **Worker pool**.
- `pool_get` borrows a Worker (a running thread + its mboxes). `pool.put` returns it.
- Each Worker thread proc casts `rawptr` to `^Worker` and calls `worker_run`. It declares nothing on its own stack.
- `worker_factory` spawns the thread and initializes the mboxes. `worker_dispose` closes mboxes, joins the thread, frees the struct.
- Worker Master runs on the heap. No stack escapes.

---

## 6. Idiom mapping

Each design decision from the dialog maps to one or more idioms.

| Design decision | Idiom(s) |
|---|---|
| `JobTicket` and `PDLChunk` carry `string` fields | `disposable-itm`, `dispose-contract`, `t-hooks` |
| Send a disposable job item safely (cleanup if send fails) | `maybe-container`, `defer-dispose` |
| Return a job item to pool after receiving | `defer-put` |
| Spool Master borrows a Worker from the thread pool | `t-hooks` (factory = spawn thread, dispose = join + destroy) |
| Spool Master and Worker Master live on the heap | `heap-master` |
| Worker thread proc holds only `^Worker`, no ITC locals | `thread-container` |
| Worker factory fails halfway through init | `errdefer-dispose` |
| Shut down pools and mboxes on exit | `defer-destroy` |
| Graceful close driven by `ByeRequest` / `ByeResponse` items | `dispose-optional` (caller drives the shutdown item) |
| `pool.put` returns a foreign Worker pointer | `foreign-dispose` |
| `reset` clears job fields for reuse; `dispose` frees strings | `reset-vs-dispose` |
| Job item carries dynamic string fields (ticket, PDL) | `disposable-itm`, `t-hooks` |
| `pool.put` on job completion triggers `reset` hook as signal | `reset-vs-dispose` |
| N Worker Masters share one input mbox (Fan-Out) | `heap-master`, `thread-container` |
| Job carries logical route names; Master resolves at runtime | `disposable-itm` (route is dynamic) |
| `Sender($T)` wraps mbox behind a proc pointer | `t-hooks` style (proc-pointer-based behavioral abstraction) |

---

## 7. Confirmed parallel: tofu mantra → matryoshka

The tofu dialog defines a **protocol** — what flows between S and R — not the internal structure of either side.

| tofu concept | matryoshka concept |
|---|---|
| S (Spool Server developer) | designs the Spool Master |
| R (RIP Worker developer) | designs the Worker side |
| `HelloRequest` message | plain item from pool (PDL type field) |
| Job request with PDL data | disposable item from pool (PDL data = `string` field) |
| Progress signal | plain item from pool, sent back on return mbox |
| `ByeRequest` / `ByeResponse` | plain items from pool triggering graceful shutdown |
| "one job per channel" | one Worker Master per active connection |
| "another HelloRequest for a second job" | second Worker borrowed from the thread pool |
| Worker instance | item in a pool of Worker threads |
| Message channel S→R | mbox (forward) |
| Message channel R→S | mbox (return: progress + bye) |

---

## 8. What comes next

This document is the spec for a future implementation stage in `examples/`.

That stage will:

1. Define the item types (`JobTicket`, `PDLChunk`, `Job`, etc.) with `T_Hooks`.
2. Implement the Spool Master and Worker Master as heap-allocated structs.
3. Connect them with two mboxes.
4. Demonstrate the full lifecycle: connect → job → progress → bye → shutdown.
5. Show a pipeline: Spool Master → RIP Master → Output Master, each stage connected by a mbox.
6. Show Fan-Out: two Worker Masters sharing one input mbox.
7. Tag every idiom use with `// [itc: <tag>]`.

The implementation stage will be planned separately once this document is reviewed and approved.

---

## 9. Job as a first-class item

A `Job` is not just a data record. It is an item in the full matryoshka sense.

- Lives in a **Pool** (owned by a Master — e.g., the Spool Master or a Job Manager Master).
- Transferred between Masters via **Mboxes**. Ownership moves with the item.
- Returned to Pool after processing (`pool.put`). The **reset hook** can signal completion to the rest of the system.
- To start a new job: `pool_get` with timeout on the free-jobs pool. If the system is at capacity, the caller blocks.

The Job item is **disposable**. It carries string fields (ticket data, PDL content) that require `dispose`, `reset`, and `factory` in `T_Hooks`.

```
Job :: struct {
    job_id:      int,
    ticket_type: Ticket_Type,
    ticket_data: string,   // dynamic — needs dispose
    pdl_type:    PDL_Type,
    content:     string,   // dynamic — needs dispose
}
JOB_HOOKS :: pool.T_Hooks(Job){
    factory = job_factory,
    reset   = job_reset,    // clear fields; can signal completion
    dispose = job_dispose,  // delete(ticket_data); delete(content)
}
```

### Pool as capacity control

Pool size = max concurrent jobs. When the pool is empty, `pool_get` blocks the caller. This is **backpressure** with no extra code.

---

## 10. Pipeline and routing

Masters can be arranged as a pipeline:

```
[Spool Master] → mbox → [RIP Master] → mbox → [Image Master] → mbox → [Output Master]
```

Each stage receives a Job item from its input mbox, processes it, sends it to the next mbox.

### Pattern A — Job carries its own route

The Job item holds a list of logical names. Each Master reads the next name, resolves it to a real mbox, sends the Job there.

```
Job :: struct {
    ...
    route:        [dynamic]string,  // e.g. ["rip", "image", "output"]
    current_step: int,
}
```

Each Master advances `current_step` and looks up the next mbox by name in a **Registry**.

The Registry maps logical name → mbox pointer.
Masters register at startup. The Job route is resolved at runtime.

```
registry_get(name: string) -> ^mbox.Mbox
registry_set(name: string, m: ^mbox.Mbox)
```

**Why Registry, not Resolver:**
- "Resolver" is overloaded — DNS, Promises, DI containers all use it.
- "Registry" names both phases: `registry_set` at startup, `registry_get` at runtime.
- No conflict with matryoshka or Odin-lang concepts.

- Routing is visible in the Job.
- Changing the route means changing the Job data, not the Masters.

### Pattern B — Master sets the next destination

Each Master knows (via configuration or its own logic) which mbox to send to next. It sets a `next_mbox` field on the Job before sending.

- Routing logic lives in Masters.
- Job struct stays smaller.

Both patterns are valid. Use Pattern A when routes vary per job. Use Pattern B when routes are fixed by configuration.

---

## 11. Configuration-driven parallelism

The number of Masters (and thus threads) processing a stage is a configuration value:

```odin
stage_workers :: 4   // create 4 Masters, all sharing the same input mbox
```

Adding workers = changing a number. The mbox and item pools stay the same.

```
[Spool Master] → [mbox] → [RIP Worker 1]
                        → [RIP Worker 2]
                        → [RIP Worker 3]
                        → [RIP Worker 4]
```

All four Workers call `mbox.recv` on the same mbox. Items are distributed by arrival. No scheduler or coordinator needed.

### Summary table

| Concept | matryoshka realization |
|---|---|
| Unit of work | `Job` item in a pool |
| Work dispatch | `pool_get` → fill Job → `mbox_send` |
| Work completion | `pool.put` → reset hook notifies system |
| Pipeline stage | one Master + one input mbox |
| Parallelism | N Masters sharing one input mbox |
| Fan-Out / Fan-In | mbox natively |
| Routing | Job carries logical names (A) or Master sets next (B) |
| Capacity control | pool size = max concurrent jobs |
| Backpressure | `pool_get` blocks when pool is empty |

Pools, Mboxes, Items, and Masters compose into any topology: single worker, pipeline, fan-out, fan-in, dynamic routing — all from the same four primitives.

---

## 12. Sender — send-only abstraction

**What it is:**

A thin struct with a context pointer and a send proc. Same pattern as `WakeUper`.

```
Sender :: struct($T: typeid) {
    ctx:  rawptr,
    send: proc(ctx: rawptr, itm: Maybe(^T)) -> bool,
}
```

**Why it exists:**

A Master in a pipeline sends an item to the next stage.
It does not need to know if the receiver is a blocking `mbox.Mailbox` or a non-blocking `loop_mbox.Mbox`.
Only the send operation is common to both. `Sender($T)` captures exactly that.

**WakeUper analogy:**

| WakeUper | Sender($T) |
|---|---|
| Abstracts "wake something" | Abstracts "send to something" |
| `ctx: rawptr` | `ctx: rawptr` |
| `wake: proc(rawptr)` | `send: proc(rawptr, Maybe(^T)) -> bool` |
| `close: proc(rawptr)` | not needed — mbox owns its lifetime |
| Zero value = no-op | Zero value = no-op (nil send = discard) |

**Adapter constructors (requirements):**

- `mbox_sender(m: ^mbox.Mailbox($T)) -> Sender($T)`
  — wraps a blocking mailbox as a Sender.
- `loop_mbox_sender(m: ^loop_mbox.Mbox($T)) -> Sender($T)`
  — wraps an event-loop mbox as a Sender.
- Both return a value type. Caller owns the Sender.
- No heap allocation. The underlying mbox is not owned by Sender.

**Requirements:**

1. `Sender($T)` is a value type (copyable, like WakeUper).
2. Zero value is valid. `nil` send proc = discard item (no-op).
3. `mbox_sender` and `loop_mbox_sender` constructors live in their respective packages or in a thin adapter file.
4. `send` proc: takes `rawptr` (cast to concrete mbox type) and `Maybe(^T)`, returns `bool` (true = sent, false = mbox closed or nil).
5. Does not own or close the underlying mbox.
6. No allocations. No mutex. One proc call through the pointer.

**Where Sender is used:**

- Pattern A pipeline routing: Registry maps logical name → `Sender($T)`.
  `registry_get` returns `Sender($T)`, not `^mbox.Mbox`.
- Pattern B: Master stores `next: Sender($T)` set at init time.
- Both patterns benefit: Master code is the same regardless of mbox type behind the Sender.
