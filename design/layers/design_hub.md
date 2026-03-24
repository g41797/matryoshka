# matryoshka — Design

> One layer at a time. Stop when you have enough.

> **This is the single source of truth.**
> All API signatures, contracts, and rules are defined here and in the linked documents.
> When these files contradict any other document — these files win.

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

### Layer 1 — PolyNode + Maybe + Builder

- [Quick Reference](layer1_quickref.md) — struct shapes, id/offset rules, Maybe contract, Builder signatures
- [Deep Dive](layer1_deepdive.md) — intrusive explanation, produce/consume examples, addendums (Maybe vs ^^PolyNode)

### Layer 2 — Mailbox + Master

- [Quick Reference](layer2_quickref.md) — Mailbox API, result enums, Master shape
- [Deep Dive](layer2_deepdive.md) — patterns (request-response, pipeline, fan-in, fan-out, shutdown)

### Layer 3 — Pool + Recycler

- [Quick Reference](layer3_quickref.md) — Pool API, modes, results, PoolHooks contracts, ID rules
- [Deep Dive](layer3_deepdive.md) — hook examples, backpressure, full lifecycle, Master with Pool

---

## Rules

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

## What matryoshka owns vs what you own

### Matryoshka owns

- `PolyNode` shape — `node` + `id`.
- `^Maybe(^PolyNode)` ownership contract across all APIs.
- Pool modes per `pool_get` call.
- Hook dispatch — `on_get` / `on_put` called with `ctx`.
- Guarantee: hooks called outside pool mutex.
- `pool_put` — sets `m^ = nil` after return, or panics on zero id.
- Panics on unknown id only when open.
- `mbox_close` — returns remaining chain as `list.List`. Caller must drain.

### You own

- Id enum definition.
- Builder (Layer 1). Your code, your rules.
- Master (Layer 2). Your code, your logic.
- All `PoolHooks` hook implementations (Layer 3). Your hooks, your policy.
- Locking inside hooks — pool makes no constraints on hook internals.
- Per-id count limits — expressed in `on_put`.
- Byte-level limits — maintain a counter in `ctx`, dispose in `on_put` when over limit.
- Receiver switch logic and casts.
- Returning every item — via `pool_put`, `mbox_send`, or `b.dtor`. Disposing manually after close.
