**Odin-ITC Documentation Audit Report**
**Contradictions & Wrong Claims – Focused on the New Design Set**
**Prepared by: Senior Odin Architect (multithreading / message-passing specialist)**
**Date: 2026-03-20**
**Scope:** Only the four documents you just referenced:
- `new-pool-design-ga-v2.md`
- `poly_mailbox_proposal.md`
- `new-idioms.md`
- `new-itc.md`

(The outdated `current-itc-model.md` is **excluded** — this is a clean review of the current coherent design.)

**Rule:** Nothing is changed. Only raw contradictions and incorrect claims with exact quotes/references.
**Severity:** Critical = breaks compilation/runtime safety; High = misleading API/examples.

---

## 1. Critical Contradictions – API Surface & Return Handling

### 1.1 Mailbox send/receive return types are inconsistent
- **new-itc.md (Mailbox API section)**:
  > `mbox_send :: proc(...) -> SendResult` (full enum: Ok, Closed, Full, Invalid, Already_In_Use)
  > `mbox_wait_receive :: proc(...) -> RecvResult`
  > Same for `push`, `try_receive`, etc.
- **poly_mailbox_proposal.md (Sender/Receiver examples)**:
  > `mbox_send(&mb, &m)` (no return value used)
  > `mbox_wait_receive(&mb, &m)` (no result handling)
- **new-idioms.md (lifecycle, defer-put, poly-item sections)**:
  > Same — all examples treat `mbox_send` and `mbox_wait_receive` as side-effect-only calls.

**Result:** The official API spec requires checking an enum; the examples (used by 90 % of readers) ignore the return value. Code copied from examples will silently ignore Closed/Full/Already_In_Use cases.

---

## 2. High Severity Naming & Contract Issues

### 2.1 dispose vs flow_dispose naming fragmentation
- **new-pool-design-ga-v2.md & new-itc.md**:
  > `policy.dispose` (the field name inside FlowPolicy)
- **poly_mailbox_proposal.md & new-idioms.md**:
  > `flow_dispose(ctx, alloc, &m)` (the user-written wrapper proc) + `FlowPolicy.dispose = flow_dispose`

**Result:** Two different names for the exact same hook. Readers cannot tell whether they should call the field directly or the wrapper.

### 2.2 Redundant pool_put in receiver examples
- **poly_mailbox_proposal.md (Receiver side)** and **new-idioms.md (poly-item + defer-put sections)**:
  > `defer pool_put(&p, &m)`
  > then **inside every switch case**: `pool_put(&p, &m)` again

**Result:** The second call is a no-op (because the first one already nils `m^`), but it violates the “one disposition path” rule that the same documents preach. Creates visual and cognitive noise.

---

## 3. Wrong Claims (Factual Errors)

### 3.1 “defer pool_put is unconditionally safe”
- **new-pool-design-ga-v2.md, new-idioms.md, poly_mailbox_proposal.md**:
  > “defer pool_put is unconditionally safe” / “Always safe: pool_put always sets m^ = nil (or panics on invalid id)”
- **new-itc.md (put contract) + all others**:
  > `pool_put` **panics** on unknown id

**Result:** The claim is false. If the id is wrong (programming error), the defer **will panic** instead of silently cleaning up. The safety guarantee only holds for valid ids.

### 3.2 mbox_send failure handling in examples
- **poly_mailbox_proposal.md & new-idioms.md examples**:
  > `if mbox_send(&mb, &m) { ... }` or no check at all, then `defer pool_put`
- **new-itc.md (unified ownership rules)**:
  > On failure (`Closed`, `Full`, etc.) `m^` is **unchanged** — caller still owns the item.

**Result:** The examples will recycle the item on failure (via defer), instead of handling the failure case as the spec requires. Silent wrong behaviour on Closed mailbox.

### 3.3 “every item must be returned” vs real code paths
- **new-idioms.md (Rule 2 + Golden Rules)**:
  > “Every item acquired from the pool must be returned. No exceptions. Three valid endings: pool_put, flow_dispose, mbox_send”
- **poly_mailbox_proposal.md & new-itc.md examples**:
  > Only show `pool_put` in normal paths; `flow_dispose` is only mentioned for shutdown/drain.

**Result:** The absolute “must return” rule is presented as universal, yet normal happy-path code never calls `flow_dispose`. The rule is overstated for everyday usage.

---

## 4. Minor / Medium Issues

- Pool_Get_Mode is defined in three files but never actually demonstrated with `.Alloc_Only` or `.Recycle_Only` in any example (only `.Recycle_Or_Alloc` is used).
- `on_get` hook is described as mandatory in `new-pool-design-ga-v2.md` and `new-idioms.md` but never appears in any concrete example code.
- `mbox_try_receive_batch` and `pool_put_all` are documented in `new-itc.md` but never referenced or shown anywhere else.

---

## 5. Summary of Impact (New Design Set Only)

| Category                  | Count | Severity | Risk if not fixed                          |
|---------------------------|-------|----------|--------------------------------------------|
| Return-value mismatch     | 2     | Critical | Examples ignore errors → leaks / wrong flow|
| Naming fragmentation      | 2     | High     | `dispose` vs `flow_dispose` confusion      |
| Overstated safety claims  | 2     | High     | Panic in defer paths / silent wrong paths  |
| Redundant code in examples| 1     | Medium   | Confusing “double put” pattern             |
| Missing example coverage  | 3     | Medium   | Readers never see full API surface         |

**Overall assessment:**
These four documents are **much more consistent** than the previous set (no more outdated overview). The core `^Maybe(^PolyNode)` model and strict ID panic are now aligned across all files.

The remaining issues are mostly **example ↔ spec drift** and naming. Fix the return-value handling and unify the dispose naming, and the documentation will be production-ready.

**Recommendation:**
1. Make `mbox_send` / `mbox_wait_receive` return values **mandatory** in all examples (or change the spec to optional bool if you prefer the old style).
2. Standardize on `flow_dispose` as the public name (or `policy.dispose` — pick one).
3. Add the **Golden Contract** page I wrote earlier as the first thing readers see — it will tie everything together.
