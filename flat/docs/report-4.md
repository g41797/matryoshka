# matryoshka — Design Audit Report

> Architect review: claims, inconsistencies, threading hazards.
> Scope: `flat/docs/*.md` (direct children only), excluding `report-3.md`.
> Date: 2026-03-27.

---

## Method

Read every layer document (quick ref + deep dive), advices, unified API reference, design hub, and advice catalog.
Cross-checked all claims, API contracts, and threading rules.
Perspective: senior distributed systems / multithreading architect.

---

## Part I — Internal Inconsistencies

Errors or ambiguities within or between the in-scope documents.

---

### I1 — `pool_get_wait` result table missing `.Already_In_Use`

**Where:** `layer3_quickref.md`, `pool_get_wait` result table shows only `.Ok`, `.Not_Available`, `.Closed`.

**But:** The validation order table in the same document states "Both `pool_get` and `pool_get_wait` apply the same entry checks" and lists `m^ != nil` → `.Already_In_Use` at priority 2.

`.Already_In_Use` is missing from the `pool_get_wait` result table. The validation order table is correct. The result table is incomplete.

---

### I2 — Duplicate `m^ = nil` and closing brace in `layer1_deepdive.md`

**Where:** `layer1_deepdive.md`, lines 160–163.

The `dtor` function ends with `m^ = nil` and `}` appearing twice. Copy/paste artifact. The actual function body is duplicated.

---

### I3 — Corrupt text at end of `layer2_deepdive.md`

**Where:** `layer2_deepdive.md`, lines 357–360.

```
Builder creates. Builder destroys. Mailbox moves. No pool yet.
t.
 pool yet.
t.
```

Two overlapping fragment copies of the same sentence. Should be one clean sentence.

---

### I4 — `on_get` exception wording is ambiguous for `Available_Only`

**Where:** `layer3_quickref.md`, "on_get rule" section:

"Pool calls `on_get` on every `pool_get`. Exception: `Available_Only` when no item is stored."

The phrase "when no item is stored" implies `on_get` IS called for `Available_Only` when an item IS found. But the mode table says "`on_get` not called" for `Available_Only` without qualification, and `pool_get_wait` (which is `Available_Only` with blocking) also states "Never calls `on_get`."

The prose and the table are in tension. The table wins: `Available_Only` never calls `on_get`. The prose should be rewritten as:

"Exception: `Available_Only` — `on_get` is never called."

---

### I5 — `b.dtor(b.alloc, &m)` call syntax does not match the Builder API

**Where:** `layer2_deepdive.md`, close-drain example:

```odin
b.dtor(b.alloc, &m)
```

The Builder API defined in `layer1_quickref.md` is a standalone proc:

```odin
dtor :: proc(b: ^Builder, m: ^Maybe(^PolyNode))
```

`Builder` has no procedure fields. The correct call is `dtor(&b, &m)`. The example uses field-access syntax for a proc that is not a field.

---

## Part II — Threading Architecture Review

Not documentation errors but architectural concerns an implementor must get right.

---

### T1 — Fan-Out: "One wakes" requires `cond_signal`, not `cond_broadcast`

**Where:** `layer2_deepdive.md`, Fan-Out pattern:

"All workers call mbox_wait_receive on the same mailbox. One wakes. The others keep waiting."

**Analysis:** This guarantee requires the implementation to use `sync.cond_signal` (wake one waiter) on enqueue, not `sync.cond_broadcast` (wake all). If broadcast is used, all workers wake, N-1 of them find the queue empty, and re-block — correctness holds but throughput degrades under load due to thundering herd.

The doc makes a behavioral guarantee. The implementation must match.

---

### T2 — `pool_get_wait` returns items that were not reinitialized

`pool_get_wait` never calls `on_get`. This is correct and intentional (the doc states it clearly). But the consequence must be explicit: items returned by `pool_get_wait` are in the state left by the last `on_put` — not the clean state that `on_get` would guarantee.

A caller that uses `pool_get_wait` and then writes to the item without reinitializing is reading stale data from the previous owner. The caller is responsible for reinitializing before use. This is a contract difference from `pool_get(.Available_Or_New)` that should be called out prominently.

---

### T3 — `ctx` lifetime vs teardown order: no enforced constraint

**Where:** `layer3_quickref.md`, Hook rules:

"`ctx` must outlive the pool. Do not tie `ctx` to a stack object or any resource freed before `pool_close`."

`advices.md` Rule R9 confirms.

**Analysis:** The correct order is: close pool → drain returned items → free ctx (master). The `layer3_deepdive.md` `freeMaster` example follows this order. But the rule is stated as documentation advice, not enforced. A caller who frees master before closing the pool may see a hook fire with a freed `ctx` — use-after-free, no crash at the violation point.

**Recommendation:** The `freeMaster` template should add a comment explicitly stating the ordering constraint, not just show the order implicitly through code layout.

---

### T4 — Hook reentrancy deadlocks silently — no runtime guard

**Where:** `layer3_quickref.md`:

"Hooks must NOT call `pool_get` or `pool_put` — that re-enters the pool and deadlocks."

**Analysis:** The pool acquires a mutex for get/put, then calls the hook outside the mutex. A reentrant call from the hook would re-acquire the same mutex → deadlock on a non-recursive mutex.

Enforcement is by documentation only. In complex setups where `on_get` allocates from a shared pool (a common optimization), this rule is easy to violate accidentally.

**Recommendation:** Add an `in_hook: bool` flag (or reentrance counter) to the pool internal state. On entry to `pool_get`/`pool_put` while a hook is active: panic immediately with a clear message instead of deadlocking silently.

---

### T5 — Interrupt + batch: subtle cross-mailbox flag clearing

**Where:** `layer2_deepdive.md`, Two-mailbox interrupt + batch pattern:

```odin
case .Interrupted:
    batch := try_receive_batch(mb_data)
```

`try_receive_batch` clears the interrupted flag of the mailbox it is called on. In the example, it is called on `mb_data` — a different mailbox than `mb_ctrl` which was interrupted. No interference. But if a reader confuses which mailbox to call `try_receive_batch` on, the interrupt flag on the wrong mailbox gets cleared. The example is correct; the identity of the mailbox argument must be made explicit in the surrounding explanation.

---

### T6 — Dangling handle after `matryoshka_dispose` in teardown example

**Where:** `layer4_deepdive.md`, teardown example:

```odin
m: Maybe(^PolyNode) = (^PolyNode)(mb)
remaining := mbox_close(mb)
// drain remaining first
matryoshka_dispose(&m)
```

After `matryoshka_dispose(&m)`, the memory that `mb` points to is freed. The variable `mb` (type `Mailbox = distinct ^PolyNode`) is now a dangling pointer. Any use of `mb` after this point is use-after-free.

The teardown template should zero the handle after dispose:

```odin
matryoshka_dispose(&m)
mb = nil  // mb is now dangling — zero it
```

---

### T7 — Asymmetric error on `id == 0`: `.Invalid` (mailbox) vs panic (pool)

**Where:** `advices.md` Rule R5: "`id == 0` on `pool_put` or `mbox_send` → immediate panic or `.Invalid`."
`layer2_quickref.md` table: `m^.id == 0` → `.Invalid`.

**Analysis:** Same condition, two behaviors. `mbox_send` returns `.Invalid` — caller can recover, dispose the item. `pool_put` panics — process dies, no recovery. Rule R5 groups them as equivalent. They are not.

This asymmetry may be intentional design (pool is stricter), but it should be stated explicitly. The current wording implies they are interchangeable.

---

## Part III — Missing Specifications

---

### M1 — `try_receive_batch` behavior when interrupted AND items are available

**Where:** `layer2_quickref.md`:

"Returns empty list on: nothing available, closed, **interrupted**, any error."
"If mailbox is in interrupted state: clears the flag before returning."

These two statements conflict. The first says `try_receive_batch` returns empty when the mailbox is in interrupted state. The second says it clears the flag (implying it proceeds normally). Does it drain available items or return empty when interrupted?

A definitive specification is required.

---

### M2 — `pool_put_all` behavior when a mid-chain node panics

**Where:** `layer3_quickref.md`:

"Walks the linked list starting at `m^`, calling `pool_put` on each node. Panics on zero or unknown id in any node."

If the panic fires on node N in a chain of M nodes, nodes N+1 through M are never returned to the pool — they leak. The caller cannot pre-validate all nodes without walking the list twice. This behavior should be documented explicitly. The panic is correct for the bad node; the leak of remaining nodes is a side effect that callers must know about.

---

### M3 — `pool_close` on a pool that was `pool_new`'d but never `pool_init`'d

`pool_new` and `pool_init` are separate calls. There is a window between them where a pool exists without hooks. Whether `pool_close` on such a pool is safe (e.g., during early error teardown) is not specified.

---

## Summary Table

| ID | Severity | Category | Short description |
|---|---|---|---|
| I1 | Medium | Inconsistency | `pool_get_wait` result table missing `.Already_In_Use` |
| I2 | Low | Inconsistency | Duplicate `m^ = nil` / `}` in `layer1_deepdive.md` |
| I3 | Low | Inconsistency | Corrupt text at end of `layer2_deepdive.md` |
| I4 | Medium | Inconsistency | `on_get` exception prose conflicts with mode table for `Available_Only` |
| I5 | Medium | Inconsistency | `b.dtor(b.alloc, &m)` call syntax does not match Builder API |
| T1 | High | Threading | Fan-Out "one wakes" requires `cond_signal` — implementation must match |
| T2 | High | Threading | `pool_get_wait` returns items not reinitialized by `on_get` — callers must know |
| T3 | Medium | Threading | `ctx` lifetime ordering constraint documented but not enforced |
| T4 | High | Threading | Hook reentrancy deadlocks silently — no runtime guard |
| T5 | Medium | Threading | Interrupt + batch: mailbox identity of `try_receive_batch` call must be explicit |
| T6 | Medium | Threading | Dangling handle after `matryoshka_dispose` — teardown example should zero it |
| T7 | Medium | Threading | `id == 0` asymmetry: `.Invalid` (mailbox) vs panic (pool) — undocumented |
| M1 | High | Missing spec | `try_receive_batch` behavior when interrupted AND items available — contradictory |
| M2 | Medium | Missing spec | `pool_put_all` panics mid-chain — remaining nodes leak |
| M3 | Low | Missing spec | `pool_close` on never-initialized pool — behavior unspecified |

---

## Recommended Actions (Priority Order)

1. **Fix M1.** `try_receive_batch` interrupted + items available is contradicted within one document. Pick one behavior, state it clearly.
2. **Add runtime reentrancy guard (T4).** Hook reentrancy deadlock is invisible until it happens. A one-line `assert(!in_hook)` inside `pool_get`/`pool_put` saves future debugging hours.
3. **Document T2 prominently.** `pool_get_wait` returns a non-reinitialized item. State this as a bold warning next to the API signature, not buried in the description.
4. **Fix I4.** Replace ambiguous `on_get` prose with: "Exception: `Available_Only` — `on_get` is never called."
5. **Fix I5.** Correct `b.dtor(b.alloc, &m)` → `dtor(&b, &m)` in `layer2_deepdive.md`.
6. **Fix T6.** Add `mb = nil` / `pl = nil` after `matryoshka_dispose` in all teardown examples.
7. **Clarify T7.** Add a note that the asymmetry between `mbox_send` (`.Invalid`) and `pool_put` (panic) on `id == 0` is intentional, and explain why.
8. **Fix I1.** Add `.Already_In_Use` to `pool_get_wait` result table.
9. **Fix M2.** Document `pool_put_all` mid-chain panic leaves remaining nodes leaked.
10. **Fix I2, I3.** Textual artifacts — duplicate code block, corrupt text.
