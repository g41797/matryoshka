## Author notes

> Check this section before any execution. Highest priority.

---

## Stage 8 — ideas dump (2026-03-16, not decisions)

### What this file is
Raw thinking. Variants. Intents. Nothing here is a decision.
When Stage 8 starts for real, a proper plan goes to design/stage8_plan.md.

### Larger vision
- matryoshka = local messaging (single process, threads)
- otofu (future) = distributed messaging (processes, network), built on matryoshka
- Together: position Odin as viable for boring enterprise systems, not just games

### The claim we want to make
Odin is a real candidate for boring enterprise systems.
The ecosystem doesn't have this yet. matryoshka + otofu together start building the case.

### Documentation narrative direction
- Problem first, solution second. Not API first.
- Audience: Odin developers who want to build serious non-gamedev systems
- Show a real boring-system scenario (like spool+rip) as a dialog (like tofu's mantra.md)
- High-level flow picture before any code
- matryoshka components as the answer — not just a queue library

### Scenario thinking
- Spool+rip works as the scenario — it is a boring system, that's the point
- The dialog does not need to match existing Odin projects
- It makes the case that you could build this in Odin — aspirational, not descriptive
- Two developers designing a single-process job processor in Odin
  - Who allocates the job struct? Who frees it?
  - What if the worker is busy — does the submitter block?
  - How does progress/status come back?
  - How do we stop without losing queued jobs?
- These questions lead naturally to matryoshka components

### Odin community landscape (researched)
- Dominant: gamedev (games, engines, EmberGen/JangaFX)
- Beyond gamedev: OLS (language server), OstrichDB, odin-http (by laytan), Spall
- EmberGen threading details: not publicly documented, don't rely on it
- No existing "boring systems" in Odin — that's the gap we're pointing at

### Doc site approach (decided)
- mkdocs (Material theme) + odin-doc hybrid
- mkdocs for narrative pages (problem, concepts, flows, scenario dialog)
- odin-doc API output as a subdirectory within the mkdocs site
- Reference: tofu project at /home/g41797/dev/root/github.com/g41797/tofu/docs_site/

### Mailbox description problems (to fix in Stage 8)
- Mailbox($T): "Blocks the thread until a message arrives" — missing timeout and interrupt
- loop_mbox.Mbox($T): "for nbio loops" — wrong, it works with any WakeUper
- Both need rewriting in README.md and docs/README.md

### What Stage 8 is NOT yet decided
- Exact page structure and navigation
- Exact scenario dialog content
- Build process details
- CI changes
- Stage numbering after Stage 8

---

## Orthogonality in matryoshka (2026-03-16)

### 1. WakeUper ⊥ loop_mbox

`WakeUper` is a plain struct with two function pointers (`wake`, `close`). No dependency on `loop_mbox`.

`loop_mbox` takes a `WakeUper` at init. Does not care what is inside it.

Two current implementations:
- `wakeup.sema_wakeup` — semaphore, no nbio
- `nbio_mbox` — nbio-specific wakeup

A third implementation can be injected without changing `loop_mbox`.

### 2. pool ⊥ mailbox

`pool` does not import the mailbox. The mailbox does not import pool.

You can use:
- mailbox without pool (heap-allocate every message)
- pool without mailbox (batch pre-allocation only)
- both together (common case)

They connect only through the user's message struct.

### 3. Message type ⊥ queue/mailbox

The mailbox is `Mailbox($T)`. Generic. One constraint: your struct must have `node: list.Node`. The mailbox does not own, copy, or inspect your struct.

Your struct is orthogonal to the transport.

### 4. Blocking mailbox ⊥ loop mailbox

`Mailbox($T)` and `loop_mbox.Mbox($T)` are two independent waiting strategies on the same MPSC queue model:

| | wait mechanism | thread model |
|---|---|---|
| `Mailbox($T)` | mutex + condition | any worker thread |
| `loop_mbox.Mbox($T)` | WakeUper | event-loop thread only |

Same ownership idioms. Same drain-on-close contract. Different wait.

### What is NOT orthogonal (by design)

Two struct field requirements:
- `node: list.Node` — required for any mailbox
- `allocator: mem.Allocator` — required if using pool

Constraints of the intrusive design. Intentional tradeoffs for zero-copy. Not a flaw.

### Short answer

The core axes are independent: transport (mailbox type), wait mechanism (WakeUper), memory strategy (pool or free), and message type (your struct). You can vary each axis without changing the others.
