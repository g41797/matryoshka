# matryoshka — Design

> One layer at a time. Stop when you have enough.

> **This is the single source of truth.**
> All API signatures, contracts, and rules are defined here and in the linked documents.
> When these files contradict any other document — these files win.

---

## Advices

[Advices](advices.md) contains recommended patterns for writing matryoshka code.
All new code and changes must be checked against its content.

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
| 4 | + Meta (Infra as Items) | — |

**The rule:** move to the next layer because you need it — not because it is there.

> This is an internal design principle, not user documentation.
> When writing examples, docs, or new features — always ask:
> which is the minimum layer this belongs to?

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

## Layer Documents

Each layer has a **Quick Reference** (API signatures, contracts, tables) and a **Deep Dive** (diagrams, examples, patterns).

### Block 1 — PolyNode + Maybe + Builder

- [Quick Reference](block1_quickref.md) — struct shapes, id/offset rules, Maybe contract, Builder signatures
- [Deep Dive](block1_deepdive.md) — intrusive explanation, produce/consume examples, addendums (Maybe vs ^^PolyNode)

Concepts from Block 1 form the fundamental building blocks for all subsequent layers of Matryoshka, providing essential item structure and ownership semantics.

### Block 2 — Mailbox + Master

- [Quick Reference](block2_quickref.md) — Mailbox API, result enums, Master shape
- [Deep Dive](block2_deepdive.md) — patterns (request-response, pipeline, fan-in, fan-out, shutdown)

### Block 3 — Pool + Recycler

- [Quick Reference](block3_quickref.md) — Pool API, modes, results, PoolHooks contracts, ID rules
- [Deep Dive](block3_deepdive.md) — hook examples, backpressure, full lifecycle, Master with Pool

### Block 4 — Meta — Infrastructure as Items

- [Quick Reference](block4_quickref.md) — handle definitions, matryoshka_dispose signature, unified creation
- [Deep Dive](block4_deepdive.md) — dynamic topology, self-send patterns, teardown unification

---

## What matryoshka owns vs what you own

### Matryoshka owns

- `PolyNode` shape — `node` + `id`.
- `^MayItem` ownership contract across all APIs.
- Pool modes per `pool_get` call.
- Hook dispatch — `on_get` / `on_put` called with `ctx`.
- Guarantee: hooks called outside pool mutex.
- `pool_put` — sets `m^ = nil` after return, or panics on zero id.
- Panics on unknown id only when open.
- `mbox_close` — returns remaining chain as `list.List`. Ownership transfers to caller.

### You own

- Id enum definition.
- Builder (Block 1). Your code, your rules.
- Master (Block 2). Your code, your logic.
- All `PoolHooks` hook implementations (Block 3). Your hooks, your policy.
- Locking inside hooks — pool makes no constraints on hook internals.
- Per-id count limits — expressed in `on_put`.
- Byte-level limits — maintain a counter in `ctx`, dispose in `on_put` when over limit.
- Receiver switch logic and casts.
- Returning every item — via `pool_put`, `mbox_send`, or `dtor`. Disposing manually after close.
