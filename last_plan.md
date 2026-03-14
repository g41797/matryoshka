# Plan: Loop_Mailbox Enhancement — Multi-Package Library

## Context

`Loop_Mailbox` uses a mutex-protected intrusive list.
This plan transforms it into a lock-free MPSC-based design and restructures
the repository into a proper multi-package library with clean separation.

---

## Process

Implementation is iterative: one stage at a time.
After each stage:
- Full regression (build all + test all)
- Rethink — update plan if needed
- Docs, README sync, comments, AI-ish check
- Update `design/STATUS.md` checkpoints
- Update `last_plan.md` (full plan, not a diff)

---

## Key Decisions

- `Mailbox($T)` — copyable; stays in `mbox/`; no mpsc/wakeup dependency
- `Loop_Mailbox($T)` — NOT copyable after init; moves to own `loop_mbox/` package
- `loop_mbox/` is the "abstract base": generic queue + generic wakeup, no nbio
- `nbio_mbox/` is the nbio concrete implementation of `loop_mbox/`
- Extra import path from split is developer-side concern only, not client concern
- Pool stays in this repo
- **Unit tests**: white-box, inside the package folder, same package name
- **Functional tests**: black-box public API, separate `*_tests/` folder (existing pattern)
- **Examples in small packages** (mpsc/, wakeup/): `@(private) _example_*` procs in `*_test.odin`,
  called from thin `@(test)` wrappers. One file holds unit tests + examples. Safe — `@(test)` procs
  are excluded from `odin build` production output.
- **examples/ folder**: stays as cross-package integration showcase (negotiation, stress, etc.)
  after Stage 6. Not split per-package.
- **Per-package README.md**: deferred to Stage 8. Note for Stage 8: user wants per-package READMEs
  with snippets ("willings") — do not forget.
- WakeUper is caller-initialized, passed to `init_loop_mailbox`, `loop_mbox` owns copy
- Caller frees Loop_Mailbox struct memory; `close_loop` frees internal resources only

---

## Final package structure

```
odin-mbox/
  mbox/               (Mailbox — blocking, no mpsc/wakeup deps)
    mbox.odin
    doc.odin
    mbox_test.odin    (unit tests, package mbox)
  loop_mbox/          (Loop_Mailbox — generic, non-blocking)
    loop_mbox.odin
    doc.odin
    loop_mbox_test.odin  (unit tests, package loop_mbox)
  nbio_mbox/          (nbio concrete impl of loop_mbox)
    nbio_mbox.odin
    doc.odin
    nbio_mbox_test.odin  (unit tests, package nbio_mbox)
  mpsc/               (Vyukov lock-free queue)
    queue.odin
    doc.odin
    queue_test.odin   (unit tests + @private examples + @test wrappers, package mpsc)
  wakeup/             (WakeUper interface + semaphore implementation)
    wakeup.odin
    doc.odin
    wakeup_test.odin  (unit tests + @private examples + @test wrappers, package wakeup)
  pool/               (existing — unchanged structure)
    pool.odin
    doc.odin
  examples/
  tests/              (functional black-box tests: mbox + loop_mbox)
  pool_tests/         (functional black-box tests: pool — existing)
  design/
```

Dependency graph:
```
mpsc/       — no deps
wakeup/     — core:sync
pool/       — core:mem, core:sync, intrusive/list, wakeup/
mbox/       — core:sync, intrusive/list
loop_mbox/  — mpsc/, wakeup/
nbio_mbox/  — loop_mbox/, wakeup/, core:nbio
```

---

## Stages

### Stage 1 — init returns error ✓ DONE (Session 74)

**Claim**: `init_loop_mailbox` should return `Loop_Mailbox_Error`.
Initialization can fail (`loop == nil`, keepalive timer returns nil).

**Verdict**: Valid. Current init ignores `nbio.timeout` return value silently.

**Proposal** (interim — superseded by Stage 6 final form):

```odin
Loop_Mailbox_Error :: enum {
    None,
    Invalid_Loop,
    Keepalive_Failed,
}

init_loop_mailbox :: proc(
    m: ^Loop_Mailbox($T),
    loop: ^nbio.Event_Loop,
) -> Loop_Mailbox_Error
where intrinsics.type_has_field(T, "node"),
      intrinsics.type_field_type(T, "node") == list.Node {
    if loop == nil { return .Invalid_Loop }
    m.loop = loop
    m.keepalive = nbio.timeout(time.Hour * 24, _noop, loop)
    if m.keepalive == nil { return .Keepalive_Failed }
    return .None
}
```

**Breaking change**: all callers handle error return.
Files: `tests/loop_test.odin` (4 tests), `examples/negotiation.odin`.

**Design doc**: `design/loop-mbox-enhancement.md` — Stage 1 section.

---

### Stage 2 — Verify close_loop keepalive handling ✓ DONE (Session 74)

**Claim**: `close_loop` must remove keepalive outside the mutex.

**Verdict**: Already correct. Current implementation matches exactly.
No code change. Document and close.

**Design doc**: `design/loop-mbox-enhancement.md` — Stage 2 section.

---

### Stage 3 — mpsc/ package (Vyukov queue) ✓ DONE (Session 74)

**Claim**: Replace mutex + intrusive list with lock-free Vyukov MPSC queue.

**Verdict**: Valid with caveats:
1. `stub: list.Node` embedded — Queue NOT copyable after init
2. Stall state: `pop` returns nil mid-push — retry on next tick; document in `pop`'s comment
3. Length counter — match `core:sync/chan` behavior (add atomic counter); `len > 0` does NOT guarantee `pop` succeeds (stall state) — document this in `pop`'s comment
4. `close_loop` drain: repeated `pop`, rebuild `list.List` for return value
5. `closed` flag must use `intrinsics.atomic_load/store`

**New files**:
```
mpsc/queue.odin        — Queue($T), init/push/pop
mpsc/doc.odin
mpsc/queue_test.odin   — unit tests (package mpsc, white-box)
```

```odin
package mpsc

Queue :: struct($T: typeid) {
    head: ^list.Node,  // atomic — producer side
    tail: ^list.Node,  // consumer side only
    stub: list.Node,   // sentinel; NOT copyable after init
    len:  int,         // atomic counter
}
// init, push (multi-producer safe), pop (single consumer only)
```

**Updated `Loop_Mailbox` after Stage 3** (still in root, pre-Stage 6):
```odin
Loop_Mailbox :: struct($T: typeid) {
    queue:     mpsc.Queue(T),
    loop:      ^nbio.Event_Loop,
    keepalive: ^nbio.Operation,
    closed:    bool,  // atomic
}
```

**Design doc**: `design/loop-mbox-enhancement.md` — Stage 3 section.

---

### Stage 4 — wakeup/ package (WakeUper interface + sema impl) ✓ DONE (Session 74)

**Claim**: Separate the wakeup mechanism from the queue.

**Verdict**: Valid. WakeUper is a value type (proc fields + rawptr) — copyable.
`loop_mbox` stores a copy and owns it (calls `close` in `close_loop`).

**New files**:
```
wakeup/wakeup.odin       — WakeUper struct + sema_wakeup
wakeup/doc.odin
wakeup/wakeup_test.odin  — unit tests (package wakeup, white-box)
```

```odin
package wakeup

WakeUper :: struct {
    ctx:   rawptr,
    wake:  proc(rawptr),   // NOT #contextless — callers may use logger/allocator
    close: proc(rawptr),   // NOT #contextless — callers may use logger/allocator
}

// sema_wakeup: WakeUper backed by sync.Semaphore.
// Useful for non-nbio loops and unit tests.
sema_wakeup :: proc(allocator := context.allocator) -> WakeUper
```

**Decision**: WakeUper procs do NOT use `#contextless`. Follows existing codebase pattern (`nbio` callbacks, pool `reset`). Users may need `context.logger` inside wake callbacks.

**Updated `Loop_Mailbox` after Stage 4** (still in root, pre-Stage 6):
```odin
Loop_Mailbox :: struct($T: typeid) {
    queue:  mpsc.Queue(T),
    waker:  wakeup.WakeUper,
    closed: bool,  // atomic
}

Loop_Mailbox_Error :: enum { None, Invalid_Waker }

init_loop_mailbox :: proc(m: ^Loop_Mailbox($T), w: wakeup.WakeUper) -> Loop_Mailbox_Error
```

**Design doc**: `design/loop-mbox-enhancement.md` — Stage 4 section.

---

### Stage 5 — Pool WakeUper  ✓ DONE (Session 75)

**Purpose**:
Add optional `wakeup.WakeUper` to the pool so event-loop callers can be notified
when a message returns to an empty pool, instead of blocking on `sync.Cond`.

**Depends on**: Stage 4 (`wakeup/` package must exist).

**Behavior** (additive — Cond blocking unchanged):
- `get(.Pool_Only, 0)` returns `.Pool_Empty` and sets `p.empty_was_returned = true`.
- `get(.Pool_Only, timeout<0 or >0)` still blocks on `sync.Cond` (unchanged).
- `put`: signals `sync.Cond` (unchanged). Calls `waker.wake` only when pool transitions empty→non-empty AND `empty_was_returned` was true. Always clears flag. Wake called outside mutex. (Zig-aligned — original plan said: wake if flag set, ignoring empty state.)
- `destroy`: calls `cond_broadcast` (unchanged), then calls `waker.close` only — no wake. (Zig-aligned — original plan said: wake + close.)
- WakeUper is optional. Pass `{}` to `init` for none.

**Pool struct changes**:
```odin
Pool :: struct($T: typeid) {
    // ... existing fields ...
    waker:              wakeup.WakeUper, // optional — notify non-blocking callers
    empty_was_returned: bool,            // set when get(.Pool_Only,0) found empty
}
```

**`init` change**: add `waker: wakeup.WakeUper` parameter after `reset`.

**-vet workaround**: add `@(private) _PoolWaker :: wakeup.WakeUper` to `pool.odin`.

**Files changed**:
- `pool/pool.odin` — add `waker`, `empty_was_returned`; update `init`/`get`/`put`/`destroy`
- `pool_tests/pool_test.odin` — add tests: WakeUper wakes on put, waker.close on destroy

**Design doc**: `design/loop-mbox-enhancement.md` — Stage 5 section.

---

### Stage 5b — Pool Hardening  ✓ DONE (Session 76)

**Purpose**: Follow-up fixes and tests before repartitioning.
Decided after reading Zig Pool.zig and reviewing Strategic Analysis section.

**pool/pool.odin changes**:
- Re-init guard: `init` returns `(false, .Closed)` if `p.state == .Active`.
  Prevents silent free-list leak on double-init. Guard fires before any field is modified.
- `length` proc: returns `curr_msgs` under mutex. Thread-safe. Same where clause as all pool procs.

**pool_tests/ restructure**:
- 5 heavy threaded tests move from `pool_test.odin` to `pool_tests/edge_test.odin`:
  test_pool_get_timeout_elapsed, test_pool_get_timeout_put_wakes,
  test_pool_get_timeout_destroy_wakes, test_pool_many_waiters_partial_fill,
  test_pool_destroy_wakes_all (with _Put_Wakes_Ctx, _Destroy_Wakes_Ctx, _N_Pool_Ctx).
- 2 new tests added to `pool_test.odin`: test_pool_reinit_active, test_pool_length.
- `pool_tests/edge_test.odin` (NEW): 5 moved + 5 new stress/edge tests:
  test_pool_stress_high_volume (10 threads × 1000 ops),
  test_pool_max_limit_racing (concurrent puts at cap),
  test_pool_shutdown_race (put+reset window during destroy),
  test_pool_idempotent_destroy (10 threads call destroy simultaneously),
  test_pool_allocator_integrity (custom allocator, verify all allocs tracked).

**Test counts**: pool_test.odin 26 + edge_test.odin 10 = 36 total pool_tests.
All other suites unchanged.

**Files changed**:
- `pool/pool.odin`
- `pool_tests/pool_test.odin`
- `pool_tests/edge_test.odin` (NEW)
- `design/loop-mbox-enhancement.md` (Stage 5b section)
- `design/STATUS.md` (session entry)

---

### Stage 6a — try_mbox Package  ✓ DONE (Session 77)

**Purpose**: Rename `poll_mbox/` → `try_mbox/`. Package rename + function rename. No logic changes.

`poll_mbox` was the working name. `poll` and `pool` differ by one letter — easy to misread, easy to mistype.
Agreed name: `try_mbox`. Receive function: `try_receive`.

`poll_mbox/` exists with a working implementation (10 tests pass).

**Name rationale**: `try_mbox` — the consumer tries to receive; non-blocking by nature.
`loop` was rejected: implies nbio event loop, but this package has no nbio dependency.

**Why NOT copyable**:
`mpsc.Queue(T)` contains a `stub` sentinel field. After `mpsc.init`, `head` and `tail`
point to `&stub` inside the struct. Copying invalidates those pointers.
`Mbox` inherits this. `init` allocates on heap and returns `^Mbox(T)` — prevents accidental
stack-allocation and copy.

**Design**:
- `try_mbox.Mbox(T)` — MPSC queue based mailbox. Not copyable after init.
- `init` allocates on heap, returns `^Mbox(T)`.
- `wakeup.WakeUper` optional — zero value = no notification. Consistent with pool.
- No nbio dependency. Works with any WakeUper or none.
- `closed: bool` — atomic via `intrinsics.atomic_*`.
- Receive function is named `try_receive` — explicit non-blocking attempt.

**nbio_mbox integration (Stage 6b)**: factory pattern.
`init_nbio_mbox` creates the nbio WakeUper and returns `^try_mbox.Mbox(T)`.
Caller imports root `mbox` once for init, then uses `try_mbox` directly.
No wrapper type, no redirect procs, no `using`.

**API**: `init`, `send`, `try_receive`, `close`, `length`, `destroy`.
`close` returns `(list.List, bool)` — unprocessed messages + was_open flag.

**Stall note**: `try_receive` returns `(nil, false)` on MPSC stall — caller retries on next tick.
`close` drain may miss a message in transit. Call close only after all senders have stopped.

**What changes** (poll_mbox → try_mbox):
- `package poll_mbox` → `package try_mbox`
- proc `receive` → `try_receive`
- test names: `test_send_receive_basic` → `test_send_try_receive_basic`, `test_receive_empty` → `test_try_receive_empty`
- doc.odin: update description line referencing `receive`
- `poll_mbox/` folder: DELETE

**Review findings** (apply during implementation):
- `_MQ` alias: mpsc.Queue(T) is a generic struct field in Mbox — keep alias, `-vet` needs it.
- `_MA` alias: mem.Allocator is a generic struct field in Mbox — keep alias, `-vet` needs it.
- test comment fix: "wake should be called once per send" → "wake should be called once per send; 3 sends → count == 3"

**Files**:
- `poll_mbox/` (entire folder) — DELETE
- `try_mbox/mbox.odin` (NEW) — package try_mbox
- `try_mbox/doc.odin` (NEW)
- `try_mbox/mbox_test.odin` (NEW) — 10 unit tests (white-box, same package)

**Tests (10)**:
1. `test_init_destroy`
2. `test_send_try_receive_basic`
3. `test_try_receive_empty`
4. `test_send_closed`
5. `test_close_returns_remaining`
6. `test_close_idempotent`
7. `test_length`
8. `test_waker_called_on_send`
9. `test_waker_close_on_close`
10. `test_no_waker`

---

### Stage 6b — loop_mbox → nbio_mbox (factory refactor)  ✓ DONE (Session 77)

**Purpose**: Replace `loop_mbox.odin` with `nbio_mbox.odin` (factory only). Migrate callers.

**Decisions**:
- `loop_mbox.odin` **renamed** to `nbio_mbox.odin` — stays in root, still `package mbox`
- `mbox.odin` and `nbio_mbox.odin` both remain in root. No folder split.
- `nbio_mbox` becomes a **factory only**: `init_nbio_mbox($T, loop, allocator) -> (^try_mbox.Mbox(T), Loop_Mailbox_Error)`
- `Loop_Mailbox` struct, `send_to_loop`, `try_receive_loop`, `close_loop`, `stats` — all deleted
- `Loop_Mailbox_Error` enum **kept** (used as return type of init)
- `_noop`, keepalive creation, and wakeup state move from loop_mbox into nbio_mbox

**Dependency**:
```
nbio_mbox.odin (package mbox) — imports try_mbox/, wakeup/, core:nbio, core:time, core:mem
```

**Internal state** (heap-allocated, same pattern as wakeup._Sema_State):
```odin
@(private)
_NBio_State :: struct {
    loop:      ^nbio.Event_Loop,
    keepalive: ^nbio.Operation,
    allocator: mem.Allocator,
}
```

**WakeUper callbacks**:
- `_nbio_wake`:  `nbio.timeout(0, _noop, state.loop)` — zero-duration no-op wakes loop
- `_nbio_close`: `nbio.remove(state.keepalive)`, then `free(state, state.allocator)`

**API**:
```odin
// init_nbio_mbox allocates a try_mbox.Mbox wired to the nbio event loop.
// Returns (nil, .Invalid_Loop) if loop is nil.
// Returns (nil, .Keepalive_Failed) if keepalive timer or Mbox allocation fails.
init_nbio_mbox :: proc(
    $T: typeid,
    loop: ^nbio.Event_Loop,
    allocator := context.allocator,
) -> (^try_mbox.Mbox(T), Loop_Mailbox_Error)
where intrinsics.type_has_field(T, "node"),
      intrinsics.type_field_type(T, "node") == list.Node
```

**Callers updated**:

`tests/loop_test.odin` — 4 tests:
- `mbox.init_loop_mailbox(&lm, loop)` → `mbox.init_nbio_mbox(Msg, loop)`
- `mbox.send_to_loop(&lm, msg)` → `try_mbox.send(m, msg)`
- `mbox.try_receive_loop(&lm)` → `try_mbox.try_receive(m)`
- `mbox.close_loop(&lm)` → `try_mbox.close(m)` + `try_mbox.destroy(m)`
- `mbox.stats(&lm)` → `try_mbox.length(m)`

`examples/negotiation.odin` — same pattern:
- `loop_mb: mbox.Loop_Mailbox(Msg)` → `loop_mb: ^try_mbox.Mbox(Msg)`
- init_loop_mailbox → init_nbio_mbox
- send_to_loop → try_mbox.send
- try_receive_loop → try_mbox.try_receive
- add defer try_mbox.close + try_mbox.destroy

**Files**:
- `loop_mbox.odin` — DELETE (replaced by nbio_mbox.odin)
- `nbio_mbox.odin` — NEW, package mbox, factory only
- `tests/loop_test.odin` — UPDATE, new API
- `examples/negotiation.odin` — UPDATE, new API
- `design/loop-mbox-enhancement.md` — Add Stage 6b section
- `design/STATUS.md` — Add session entry

---

### Explanation and fixes by Gemini Cli

Explanation:

```txt
  I have resolved the CI failures across all platforms by addressing a Use-After-Free vulnerability in nbio_mbox.odin. The issue was caused by
  throttled wake-up callbacks firing after the mailbox state had been freed. I implemented atomic reference counting for the _NBio_State struct to
  ensure it remains valid until all pending callbacks have completed.
  Additionally, I improved the synchronization in test_nbio_late_arrival using a
  semaphore. <====== WHY ???
  Updated all relevant tests and examples to include a final nbio.tick(0) after closing the mailbox, ensuring clean memory management.
```

Changes

```txt
- nbio_mbox.odin: Added ref_count to _NBio_State. Callback and close operations now use atomic increments/decrements to safely free memory.
- tests/nbio_mbox_edge_test.odin: Refactored test_nbio_late_arrival to use sync.Sema for deterministic execution. Added nbio.tick(0) after close
     in all tests to prevent memory leaks.
- tests/loop_test.odin: Added nbio.tick(0) after close in all tests.
- examples/negotiation.odin: Added nbio.tick(0) after close.
```


### Stage 7 — Strategic Analysis + Edge Cases  ✓ DONE (Session 78)

**Purpose**: Harden `try_mbox` and `nbio_mbox` based on deeper technical analysis.

**nbio_mbox.odin updates (§9)**:
- Problem: High-frequency `send` can overflow nbio's 128-slot cross-thread queue.
- Fix: Implement "wake-up throttling" with an atomic `wake_pending` flag in `_NBio_State`.
- CAS `false`→`true` in `_nbio_wake`; fire `nbio.timeout_poly` only if CAS succeeds.
- Flag reset by `_noop_clear` callback running inside the event-loop thread.

**try_mbox/mbox.odin updates (§10, §11)**:
- `try_receive`: Strengthened comments regarding stall handling (retry on next tick).
- `close`: Strengthened comments regarding precondition (joined senders eliminate stall).
- New API: `try_receive_all(m)` — drains the entire queue into a `list.List`. Optimized for event-loop iterations.

**Tests added**:
- `try_mbox/edge_test.odin`: `test_concurrent_producers` (10k total), `test_close_during_send_race`.
- `try_mbox/mbox_test.odin`: `test_try_receive_all_basic`.
- `tests/loop_test.odin`: `test_loop_invalid_loop`, `test_loop_high_freq_send` (10k).
- `tests/nbio_mbox_edge_test.odin`: `test_nbio_throttle_efficiency` (verifies < 50 ticks for 1k sends), `test_nbio_burst_multiproducer` (100k total), `test_nbio_pool_constancy`, `test_nbio_late_arrival` (flag-reset window safety).

**Files**:
- `nbio_mbox.odin` — UPDATE
- `try_mbox/mbox.odin` — UPDATE
- `try_mbox/mbox_test.odin` — UPDATE
- `try_mbox/edge_test.odin` — NEW
- `tests/loop_test.odin` — UPDATE
- `tests/nbio_mbox_edge_test.odin` — NEW
- `design/loop-mbox-enhancement.md` — Add Stage 7 section
- `design/STATUS.md` — Add session entry

---

### Stage 8 — Re-branding  ← NEXT

**Purpose**:
Repo name `odin-mbox` and description no longer match the library scope.
Update repo identity — name, description, tagline, root README intro — to
reflect a multi-package concurrency library, not just a mailbox.
**New name**: `odin-itc` (Inter-Thread Communication). Confirmed.

---

### Stage 9 — Documentation

**Purpose**:
Each package is a usable standalone library.
Add per-package `doc.odin` and documentation visible on GitHub.
Overhaul root README as a library index.
Covers: `mbox/`, `loop_mbox/`, `mpsc/`, `wakeup/`, `pool/`, `nbio_mbox/`.

**Willings (do not forget)**:
- Per-package `README.md` with short usage snippets (visible on GitHub without cloning)
- Root README becomes index linking to per-package READMEs

Details TBD when we reach this stage.

---

---

## Per-stage finish steps

1. Full regression — all packages build + all test suites pass
2. Update `design/loop-mbox-enhancement.md`
3. Sync README and docs/README
4. Comments check, AI-ish scan
5. Update `design/STATUS.md` checkpoint
6. Update `last_plan.md` (full plan)

---

## Strategic Analysis & Technical Refinements

### 1. MPSC Stats (Stage 3)
- **Context**: Odin's `core:sync/chan` provides `len()` and `cap()` functions.
- **Decision**: We will keep the `stats` (or `len`) function to match the Odin environment.
- **Implementation**: Add an atomic length counter to the `mpsc.Queue`. This is necessary because pointer comparison is unreliable during concurrent push/pop operations.

### 2. WakeUper Context (Stage 4)
- **Status**: Closed.
- **Decision**: Do NOT use `#contextless`. Users may need `context.logger` or custom allocators inside wake callbacks. Follows existing codebase pattern.

### 3. Re-branding (Stage 8)
- **Preferred Name**: `odin-itc` (Inter-Thread Communication).
- **Advice**: This name is very descriptive and fits well with other Odin libraries. It honors the Zig roots while acknowledging the move to a general communication toolkit.

### 4. MPSC "Stall" States
- **Technical Note**: Vyukov queues have a known "stall" state where a consumer sees a `nil` next pointer while a producer is mid-update.
- **Decision**: `Loop_Mailbox` treats stall as "temporarily empty." Next tick drains it. Document this in `pop`'s comment in `mpsc/queue.odin`. Note: `len > 0` does NOT guarantee `pop` succeeds during stall — also document in `pop`'s comment.

### 5. Documentation Strategy (Stage 9)
- **Willings**: Per-package READMEs must include a "Copy-Pasteable" example for that specific package. This makes the library more attractive to developers who only need one component (like the lock-free queue).

### 6. Pool Re-initialization Check
- **Context**: `pool.init` currently overwrites fields without checking the current state.
- **Recommendation**: Consider adding a check to return an error if `init` is called on a pool that is already `.Active`. This prevents accidental memory leaks of an existing free-list.

### 7. Pool Shutdown Race Safety
- **Context**: In `pool.put`, the `reset` hook is called outside the mutex.
- **Consideration**: We must ensure that if one thread calls `destroy` (marking state `.Closed`) while another is in the middle of a `put.reset`, no invalid operations occur. A dedicated stress test is needed to verify this specific window.

### 8. Pool Statistics API
- **Recommendation**: Add a public `pool.length(p)` or `pool.stats(p)` procedure.
- **Reason**: This matches the API pattern of `mbox` and `mpsc`, providing a read-only, consistent way to check the free-list size without accessing internal struct fields.

### 9. Nbio Waker Overwhelming Risk ✓ DONE (Session 78)
- **Analysis**: Nbio's cross-thread queue has a fixed capacity of 128. If `send` is called at very high frequency, it enqueues a no-op task for every call. This will fill the queue and cause producers to busy-wait (spin) in `nbio.exec`. It also puts pressure on the operation pool.
- **Decision**: Implement an "at most one pending wake-up" pattern using an atomic flag in `nbio_mbox`. This ensures that multiple sends only result in a single wake-up task being enqueued, which is sufficient to wake the loop.

### 10. MPSC Stall Recovery ✓ DONE (Session 78)
- **Question**: Should `try_mbox.try_receive` internally retry once on a stall (nil return when length > 0), or leave it to the caller?
- **Decision**: Leave to caller. Retrying once inside `try_receive` could improve ergonomics for high-concurrency scenarios but might hide performance issues or violate the "non-blocking" spirit if retries are frequent.

### 11. Close Semantics & Stall Window ✓ DONE (Session 78)
- **Question**: If a stall happens during the final drain in `close`, that message might be lost. Should we add a retry loop inside `close`?
- **Decision**: No retry in `close`. Precondition is joined senders. A robust implementation handles stalls naturally via the drain loop if senders are stopped.

---

## Edge Cases & Missing Tests Strategy

To keep `queue_test.odin`, `wakeup_test.odin`, and `pool_test.odin` clean as "runner of examples" and basic unit tests, we will create separate files for edge cases and stress tests.

### 1. MPSC Edge Cases (`mpsc/edge_test.odin`)
- **Concurrent Push Stress**: 10 threads pushing 10,000 items each while 1 thread pops. Verify total count and no lost items.
- **Stall State Handling**: A test that attempts to hit the Vyukov stall window (where `pop` returns `nil` but `len > 0`) under high contention.
- **Stub Recycling Verification**: Test specifically targeting the logic path where the stub sentinel is recycled when one item remains.
- **Length Consistency**: Verify `length()` accurately reflects atomic increments/decrements even if `pop` temporarily stalls.
- **Missed Test**: `test_pop_all_drains_to_zero` — ensures that repeated pops from a multi-item queue eventually return `nil` and `length()` is 0.

### 2. WakeUper Edge Cases (`wakeup/edge_test.odin`)
- **Concurrent Wake Signals**: 10 threads calling `wake()` at the same time on one `sema_wakeup`. Verify the semaphore count matches the number of calls.
- **Wake after Close Protection**: Define and test the behavior when `wake()` is called after `close()`. (Recommendation: document as undefined/illegal, but provide a safe-fail if possible).
- **Custom WakeUper**: Implement a simple dummy `WakeUper` in the test to verify the interface works without `sema_wakeup`.
- **Missed Test**: `test_ctx_persistence` — check that the `rawptr` passed to `wake` and `close` is bit-for-bit identical to the one provided during creation.

### 3. Pool Edge Cases (`pool_tests/edge_test.odin`) ✓ DONE (Session 76)
- **High-Volume Stress**: 10 threads performing 10,000 `get(.Always)` and `put` operations. Verify zero leaks and zero double-frees using the memory tracker.
- **Max Limit Racing**: Multiple threads calling `put` on a pool that is exactly at `max_msgs`. Verify `curr_msgs` never exceeds the cap and all excess messages are freed correctly.
- **Shutdown Race Stress**: 5 threads constantly calling `put` while another thread calls `destroy`. Ensures transition from `.Active` to `.Closed` is safe even if `reset` is running.
- **Idempotent Destroy**: Multiple threads calling `destroy` at the same time. Verify no crashes or double-frees.
- **Allocator Integrity**: Use a custom tracking allocator to ensure the pool never falls back to `context.allocator` for internal `new`/`free` calls.

### 4. Try_mbox Edge Cases (`try_mbox/edge_test.odin`) ✓ DONE (Session 78)
- **MPSC Stall Stress**: Create contention to trigger stall window. Verify `try_receive` eventually succeeds.
- **Close during Send Race**: 5 threads send while main closes; verify counts and no panics.

### 5. Nbio_mbox Edge Cases (`tests/loop_test.odin` updates) ✓ DONE (Session 78)
- **Wake-up Throttling Stress**: 20 threads × 5,000 sends. Verify 100,000 total received and zero nbio queue overflows.
- **Race Condition: Late Arrival**: Send a message during the flag-reset window; verify wake-up for next tick.
- **Memory/Pool Constancy**: Verify operation pool usage does not grow during sustained high-frequency signaling.
- **Throttling Efficiency**: Send 1,000 messages; verify < 50 tick iterations.

---

## Critical files

| File | Stage | Action |
|------|-------|--------|
| `loop_mbox.odin` | 1,3,4 | Modify (still in root until Stage 6) |
| `tests/loop_test.odin` | 1,4,6,7 | Update init calls + imports |
| `examples/negotiation.odin` | 1,4,6 | Update init call + imports |
| `mpsc/queue.odin` | 3 | NEW |
| `mpsc/doc.odin` | 3 | NEW |
| `mpsc/queue_test.odin" | 3 | NEW (unit tests) |
| `wakeup/wakeup.odin` | 4 | NEW |
| `wakeup/doc.odin" | 4 | NEW |
| `wakeup/wakeup_test.odin` | 4 | NEW (unit tests) |
| `pool/pool.odin` | 5,5b | Modify (add waker, length, init guard) |
| `pool_tests/pool_test.odin` | 5,5b | Add WakeUper + logic tests |
| `pool_tests/edge_test.odin` | 5b | NEW (moved + new stress tests) |
| `poll_mbox/` (entire folder) | 6a | DELETE |
| `try_mbox/mbox.odin` | 6a,7 | NEW |
| `try_mbox/doc.odin` | 6a | NEW |
| `try_mbox/mbox_test.odin` | 6a,7 | NEW (unit tests) |
| `try_mbox/edge_test.odin` | 7 | NEW (stress tests) |
| `loop_mbox.odin` | 6b | DELETE |
| `nbio_mbox.odin` | 6b,7 | NEW (package mbox, factory only) |
| `tests/nbio_mbox_edge_test.odin` | 7 | NEW (stress tests) |
| `design/loop-mbox-enhancement.md` | all | NEW (add to .gitignore) |
| `design/STATUS.md" | all | Update |
| `last_plan.md" | all | Update |

---

## Checkpoints

```
# Stages 1-5 (root still has mbox files):
odin build . -build-mode:lib -vet -strict-style -o:none -debug
odin build ./mpsc/ -build-mode:lib -vet -strict-style -o:none -debug     (Stage 3+)
odin build ./wakeup/ -build-mode:lib -vet -strict-style -o:none -debug   (Stage 4+)
odin build ./pool/ -build-mode:lib -vet -strict-style -o:none -debug
odin build ./examples/ -build-mode:lib -vet -strict-style -o:none -debug
odin test ./tests/ -vet -strict-style -disallow-do -o:none -debug
odin test ./pool_tests/ -vet -strict-style -disallow-do -o:none -debug
odin test ./mpsc/ -vet -strict-style -disallow-do -o:none -debug          (Stage 3+, unit)
odin test ./wakeup/ -vet -strict-style -disallow-do -o:none -debug        (Stage 4+, unit)

# Stage 6a (try_mbox/ added, root files untouched):
odin build ./try_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
odin test ./try_mbox/ -vet -strict-style -disallow-do -o:none -debug      (unit, 10 tests)

# Stage 6b (loop_mbox.odin deleted, nbio_mbox.odin added, callers updated):
odin build . -build-mode:lib -vet -strict-style -o:none -debug
odin build ./pool/ -build-mode:lib -vet -strict-style -o:none -debug
odin build ./mpsc/ -build-mode:lib -vet -strict-style -o:none -debug
odin build ./wakeup/ -build-mode:lib -vet -strict-style -o:none -debug
odin build ./examples/ -build-mode:lib -vet -strict-style -o:none -debug
odin test ./mpsc/ -vet -strict-style -disallow-do -o:none -debug
odin test ./wakeup/ -vet -strict-style -disallow-do -o:none -debug
odin test ./pool_tests/ -vet -strict-style -disallow-do -o:none -debug
odin test ./tests/ -vet -strict-style -disallow-do -o:none -debug

# Stage 7 (strategic analysis + edge cases done — Session 78):
odin build . -build-mode:lib -vet -strict-style -o:none -debug
odin build ./try_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
odin test ./try_mbox/ -vet -strict-style -disallow-do -o:none -debug    # 13 tests
odin test ./tests/ -vet -strict-style -disallow-do -o:none -debug       # 37 tests
odin test ./mpsc/ -vet -strict-style -disallow-do -o:none -debug
odin test ./wakeup/ -vet -strict-style -disallow-do -o:none -debug
odin test ./pool_tests/ -vet -strict-style -disallow-do -o:none -debug
# Total: 105 tests — all green
```


## For code review

Review this implementation for:
- race conditions
- memory safety issues
- architectural violations
- performance problems
- weird concurrency bugs
- missing error handling
- protocol edge cases


## For improvements

Suggest:
- simplifications
- alternative algorithms
- performance tweaks
