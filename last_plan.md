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

### Stage 5 — Pool WakeUper  ← NEXT

**Purpose**:
Add optional `wakeup.WakeUper` to the pool so event-loop callers can be notified
when a message returns to an empty pool, instead of blocking on `sync.Cond`.

**Depends on**: Stage 4 (`wakeup/` package must exist).

**Behavior** (additive — Cond blocking unchanged):
- `get(.Pool_Only, 0)` returns `.Pool_Empty` and sets `p.empty_was_returned = true`.
- `get(.Pool_Only, timeout<0 or >0)` still blocks on `sync.Cond` (unchanged).
- `put` signals `sync.Cond` (unchanged), then if `empty_was_returned == true` and `waker.wake != nil`: calls `waker.wake(waker.ctx)`, clears flag.
- `destroy` calls `cond_broadcast` (unchanged), then if waker set: `waker.wake(waker.ctx)` then `waker.close(waker.ctx)`.
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

### Stage 6 — Repartitioning

**Purpose**:
- Move `mbox.odin` → `mbox/mbox.odin` (Mailbox only, no mpsc/wakeup deps)
- Move `loop_mbox.odin` → `loop_mbox/loop_mbox.odin` (Loop_Mailbox — own package)
- Move `doc.odin` → `mbox/doc.odin`; create `loop_mbox/doc.odin`
- Create `nbio_mbox/` package: nbio WakeUper impl + convenience init
- `mbox/` loses all nbio imports
- `loop_mbox/` has no nbio dependency
- Update all import paths (breaking change for callers)
- Existing `tests/` updates: split or retarget to new package paths
- Update examples, CI scripts, build scripts

**nbio_mbox/ API**:
```odin
package nbio_mbox

// wakeup returns a WakeUper backed by a 24h keepalive timer.
wakeup :: proc(loop: ^nbio.Event_Loop) -> (wakeup_pkg.WakeUper, bool)

// init_loop_mailbox: convenience — wakeup + loop_mbox.init in one call.
init_loop_mailbox :: proc(
    m: ^loop_mbox.Loop_Mailbox($T),
    loop: ^nbio.Event_Loop,
) -> loop_mbox.Loop_Mailbox_Error
```

**Design doc**: `design/loop-mbox-enhancement.md` — Stage 6 section.

---

### Stage 7 — Re-branding

**Purpose**:
Repo name `odin-mbox` and description no longer match the library scope.
Update repo identity — name, description, tagline, root README intro — to
reflect a multi-package concurrency library, not just a mailbox.
**New name**: `odin-itc` (Inter-Thread Communication). Confirmed.

---

### Stage 8 — Documentation

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

### 3. Re-branding (Stage 7)
- **Preferred Name**: `odin-itc` (Inter-Thread Communication).
- **Advice**: This name is very descriptive and fits well with other Odin libraries. It honors the Zig roots while acknowledging the move to a general communication toolkit.

### 4. MPSC "Stall" States
- **Technical Note**: Vyukov queues have a known "stall" state where a consumer sees a `nil` next pointer while a producer is mid-update.
- **Decision**: `Loop_Mailbox` treats stall as "temporarily empty." Next tick drains it. Document this in `pop`'s comment in `mpsc/queue.odin`. Note: `len > 0` does NOT guarantee `pop` succeeds during stall — also document in `pop`'s comment.

### 5. Documentation Strategy (Stage 8)
- **Willings**: Per-package READMEs must include a "Copy-Pasteable" example for that specific package. This makes the library more attractive to developers who only need one component (like the lock-free queue).

---

## Edge Cases & Missing Tests Strategy

To keep `queue_test.odin` and `wakeup_test.odin` clean as "runner of examples" and basic unit tests, we will create separate files for edge cases and stress tests.

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

---

## Critical files

| File | Stage | Action |
|------|-------|--------|
| `loop_mbox.odin` | 1,3,4 | Modify (still in root until Stage 6) |
| `tests/loop_test.odin` | 1,4,6 | Update init calls + imports |
| `examples/negotiation.odin` | 1,4,6 | Update init call + imports |
| `mpsc/queue.odin` | 3 | NEW |
| `mpsc/doc.odin` | 3 | NEW |
| `mpsc/queue_test.odin` | 3 | NEW (unit tests) |
| `mpsc/edge_test.odin` | 3 | NEW (edge + stress tests) |
| `wakeup/wakeup.odin` | 4 | NEW + nil-check guards in _sema_wake/_sema_close |
| `wakeup/doc.odin` | 4 | NEW |
| `wakeup/wakeup_test.odin` | 4 | NEW (unit tests) |
| `wakeup/edge_test.odin` | 4 | NEW (edge + concurrent tests) |
| `pool/pool.odin` | 5 | Modify (add waker, empty_was_returned) |
| `pool_tests/pool_test.odin` | 5 | Add WakeUper tests |
| `mbox.odin` → `mbox/mbox.odin` | 6 | MOVE |
| `loop_mbox.odin` → `loop_mbox/loop_mbox.odin` | 6 | MOVE |
| `doc.odin` → `mbox/doc.odin` | 6 | MOVE |
| `loop_mbox/doc.odin` | 6 | NEW |
| `nbio_mbox/nbio_mbox.odin` | 6 | NEW |
| `nbio_mbox/doc.odin` | 6 | NEW |
| `design/loop-mbox-enhancement.md` | all | NEW (add to .gitignore) |
| `design/STATUS.md` | all | Update |
| `last_plan.md` | all | Update |

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

# Stage 6+ (packages moved):
odin build ./mbox/ -build-mode:lib -vet -strict-style -o:none -debug
odin build ./loop_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
odin build ./nbio_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
odin test ./mbox/ -vet -strict-style -disallow-do -o:none -debug          (unit)
odin test ./loop_mbox/ -vet -strict-style -disallow-do -o:none -debug     (unit)
odin test ./nbio_mbox/ -vet -strict-style -disallow-do -o:none -debug     (unit)
odin test ./tests/ -vet -strict-style -disallow-do -o:none -debug         (functional)
odin test ./pool_tests/ -vet -strict-style -disallow-do -o:none -debug    (functional)
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
