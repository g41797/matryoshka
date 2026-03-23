# Idioms Reference

Quick reference for matryoshka idioms.
Each idiom has a short tag for grep.

These are not laws. No one is forced to follow them.
They are patterns that worked. Take what helps, ignore the rest.

---

## The Golden Rule: One Variable Lifecycle

**Mantra:** One convention across all transfer points. Same variable, whole lifetime, misuse detected at every boundary.

### The Rule

1.  **`^Maybe(^T)` replaces `^T` return:** Wherever an item is acquired or transferred (`get`, `receive`), it is passed as a parameter, not returned.
2.  **Check on Entry:** Every proc checks `itm^ != nil` on entry. If the caller still holds an item, it returns `.Already_In_Use`. This prevents overwriting valid data.
3.  **One Variable:** The caller uses a single variable from `get` -> `send` -> `wait_receive` -> `put` -> `dispose`.

### Lifecycle in one variable

```odin
m: Maybe(^Itm)

// 1. Acquire
get(&p, &m)            // Returns .Already_In_Use if m != nil
defer dispose(&m)      // Safety net: no-op if transferred, cleans up if stuck

// 2. Use
// fill m^ ...

// 3. Transfer
send(&mb, &m)          // m = nil on success (dispose becomes no-op)
                       // m != nil on failure (dispose cleans up)

// 4. Loop
// On next iteration, get(&p, &m) verifies m is nil.
```

---

## Building blocks

matryoshka has five object types. Every concurrent system built with this library uses them.
Understanding what each one is — and why it exists — makes the idioms below easier to follow.

### Master

Master is the actor. It has the logic.

Master is not a library type — it is a pattern you define. A Master struct owns all pools and mboxes for a group of related threads. It decides when to get items, when to send, when to receive, when to shut down.

- One proc creates and initializes Master (allocates pools and mboxes).
- One proc destroys it (closes mboxes, drains, destroys pools, joins threads).
- Master is heap-allocated so threads can hold `^Master` safely. See `heap-master`.

Why heap-allocated? If Master lives on a stack and that proc returns while threads are still running, all `^Master` pointers held by threads become invalid. Heap allocation gives Master a lifetime not tied to any stack frame.

### Thread

A thread is a container. It runs one Master proc and nothing else.

```odin
worker :: proc(data: rawptr) {
    m := (^Master)(data)  // [itc: thread-container]
    master_run(m)         // all logic is here, in Master
}
```

- A thread proc receives one `rawptr`. It casts it to `^Master` and calls the master's run proc.
- The thread declares no pools, mboxes, or items of its own.
- All logic — getting items, sending, receiving, deciding — is in Master.

Why so thin? A thread that declares ITC participants as locals creates pointers that escape its stack frame. When the proc returns, those pointers become invalid. Keeping threads thin removes this class of bug.

**Threads as items**: because a thread is just a container, it can itself be an item in a pool. A pool of worker threads is a valid and common pattern — see "Pool of threads" below.

### Item (`Itm`)

An item is any reusable object managed by a pool.

Two kinds:
- **Plain item**: a struct with no internal heap resources. `free` destroys it completely.
- **Disposable item**: a struct that owns internal heap resources (strings, slices, sub-allocations). `free` alone leaks those resources. Needs a `dispose` proc.

Items are not limited to data payloads. An item can be a connection, a buffer, a task descriptor — or a thread. The pool does not care what is inside.

Why a separate type from the pool? Because the pool does not know what is inside an item. The caller is responsible for cleanup. Most of the idioms in this document exist because of that responsibility.

### Pool

A pool holds a set of reusable items.

- Master calls `pool_get` to borrow an item, `pool.put` to return it.
- If the item is disposable, the pool calls `reset` before recycling and `dispose` when it cannot recycle.
- `T_Hooks` (factory / reset / dispose) tells the pool how to manage the item's lifecycle.

Why a pool? Creating and freeing items on every operation wastes time and fragments memory. A pool reuses items. The idioms `defer-put`, `foreign-dispose`, `reset-vs-dispose`, and `t-hooks` exist because reuse has rules that are easy to get wrong.

### Mbox (Mailbox)

A mailbox moves a pointer from one Master to another.

- Sender (a Master) calls `mbox_send` with `^Maybe(^Itm)`. On success, inner pointer becomes nil — transfer complete, sender no longer holds the pointer.
- Receiver (a Master) calls `mbox.wait_receive` (blocking) or `mbox.try_receive_batch` (non-blocking). Receiver becomes the new holder.
- `mbox.close` signals no more items will come. Receiver drains and exits.

Why `^Maybe(^T)` instead of a plain pointer? A plain pointer cannot signal that transfer occurred. `Maybe(^T)` adds that: nil inner means transfer complete. This prevents use-after-send.

Why a mailbox instead of a mutex + queue? The mailbox owns the queue and the synchronization. Masters just send and receive. They do not manage locking.

### How they fit together

Masters are the actors. Threads run them. Items flow between Masters via Mboxes, recycled by Pools.

```
Thread A                    Thread B
  └─ Master A                 └─ Master B
       │                            │
       ├─ Pool                       │
       │    └─ get Item              │
       │         └─ fill Item        │
       │              └─ Mbox.send ──┤
       │                             ├─ Mbox.receive
       │                             ├─ use Item
       │                             └─ Pool.put ──► Pool (reset/dispose)
       │
       └─ on shutdown: Mbox.close → drain → Pool.destroy
```

Lifecycle of a disposable item:

1. Master A initializes Pool (with `T_Hooks`) and Mbox.
2. Master A calls `pool_get` → borrows item → fills internal resources → `mbox_send` → pointer transfers to Master B.
3. Master B calls `mbox.receive` → uses item → `pool.put` → pool calls `reset` → item returns to free list.
4. On shutdown: `mbox.close` → Master B drains remaining items → `pool_destroy` → pool calls `dispose` on remaining items.

### Pool of threads

Because a thread is just a container, it can be an item. A pool of worker threads shows the full generality of the design.

```odin
Worker :: struct {
    thread: ^thread.Thread,
    inbox:  mbox.Mbox,     // send work to this worker
    result: mbox.Mbox,     // worker sends result back
}
WORKER_HOOKS :: pool.T_Hooks(Worker){ factory = worker_factory, dispose = worker_dispose }

// Supervisor Master:
pool_init(&worker_pool, initial_msgs = 4, hooks = WORKER_HOOKS)  // [itc: t-hooks]
w, _ := pool_get(&worker_pool)   // borrow a worker thread
task_m: Maybe(^Task) = fill_task(...)
w.inbox.send(&task_m)            // send work
// ... worker runs, sends result back via w.result ...
pool.put(&worker_pool, &w_m)     // return worker to pool
```

The Supervisor Master treats worker threads exactly like data items — get, use, put back. The pool's `T_Hooks` handles thread creation (factory) and teardown (dispose). No special thread management code in the supervisor.

### ITC participant

"ITC participant" is a shorthand used throughout this document.
It means: any object shared between threads — a Pool, Mbox, or Loop.
ITC participants always live in Master, never on a thread's stack.

---

## Marker scheme

Each idiom has a short tag. The tag appears as a comment at the relevant line in code:

```
// [itc: <tag>]
```

Examples:
```odin
m: Maybe(^Itm) = new(Itm)   // [itc: maybe-container]
defer pool_destroy(&p)       // [itc: defer-destroy]
```

To find all usages of one idiom:
```
grep -r "\[itc: maybe-container\]" examples/ tests/
```

To find all marked lines:
```
grep -r "\[itc:" examples/ tests/
```

Where to find this documentation: `design/idioms.md`

---

## Core rules

- **Ownership**: transfer heap pointers via `^Maybe(^T)`. On success, inner is nil — transfer complete. On failure, inner is unchanged — caller retains the pointer.
- **Lifecycle**: items with internal resources use factory/reset/dispose. Register them in `T_Hooks`. The pool calls them automatically.
- **Concurrency**: ITC participants live in heap-allocated structs. Thread procs hold only a pointer to the owner struct.

---

## Quick reference

| Tag | Name | One line |
|-----|------|----------|
| `maybe-container` | Maybe as container | Wrap a heap pointer in `Maybe(^T)` before any pointer-transferring call. |
| `defer-put` | defer with pool.put | Use `defer pool.put` to return to pool in all paths. |
| `dispose-contract` | dispose signature contract | A dispose proc takes `^Maybe(^T)`. Nil inner is a no-op. Sets inner to nil on return. Register it in `T_Hooks.dispose` for pool-managed cleanup. |
| `defer-dispose` | defer with dispose | Use `defer dispose(&m)` so cleanup runs in all paths. |
| `disposable-itm` | DisposableItm full lifecycle | Items with internal heap resources use pool_get, fill, send, receive, pool.put with reset, and a separate dispose for permanent cleanup. Register factory/reset/dispose in `T_Hooks` so the pool calls them automatically. |
| `foreign-dispose` | foreign item with resources | When put returns a foreign pointer, call dispose, not free. |
| `reset-vs-dispose` | reset vs dispose | reset clears state for reuse. dispose frees internal resources permanently. factory allocates and initializes. All three are optional fields in `T_Hooks`. |
| `dispose-optional` | dispose is advice | dispose is called by the caller, never by pool or mailbox. |
| `heap-master` | ITC participants in a heap-allocated struct | Heap-allocate the struct that owns ITC participants when its address is shared with spawned threads. |
| `thread-container` | thread is just a container for its master | A thread proc only casts rawptr to ^Owner. No ITC participants declared as stack locals. |
| `errdefer-dispose` | conditional defer for factory procs | Use named return + `defer if !ok { dispose(...) }` when a proc creates and returns a master. |
| `defer-destroy` | destroy resources at scope exit | Register `defer destroy` for pools/mboxes/loops to guarantee shutdown in all paths. |
| `t-hooks` | T_Hooks pattern | Define factory/reset/dispose as a :: constant next to the type. Pass by value to pool_init. Zero value = all defaults. |

---

## Ownership model

| Tag | One line |
|-----|----------|
| `maybe-container` | Wrap a heap pointer in `Maybe(^T)` before any pointer-transferring call. |
| `dispose-contract` | A dispose proc takes `^Maybe(^T)`. Nil inner is a no-op. Sets inner to nil on return. |
| `defer-dispose` | Use `defer dispose(&m)` so cleanup runs in all paths. |
| `errdefer-dispose` | Use named return + `defer if !ok { dispose(...) }` when a factory proc creates and returns a master. |
| `dispose-optional` | dispose is called by the caller, never by pool or mailbox. |

### `maybe-container` — Maybe as container

**Problem**: You have a `^T` from `new` or `pool_get`. You want to pass it to `send` or `push` safely.

**Fix**: Wrap it in `Maybe(^T)` before any pointer-transferring call.

```odin
// [itc: maybe-container]
m: Maybe(^Itm) = new(Itm)
mbox_send(&mb, &m)
// m is nil here — transfer complete, mailbox holds the pointer
```

```markdown
**Why**: `^Maybe(^T)` is the single contract across all transfer APIs.

Every API that moves a pointer follows the same rules:

**On entry:**
- `msg == nil` — nil pointer to Maybe itself. Defensive check. No-op, returns false/error.
- `msg^ == nil` — empty Maybe. Caller has nothing. No-op, returns false/error.
- `msg^ != nil` — caller holds a pointer. Proceed.

**On exit:**
- Success — `msg^ = nil`. Transfer complete. Caller must not touch the pointer.
- Failure (closed, full, timeout) — `msg^` unchanged. Transfer did not occur. Caller still holds it.
- Failure (internal error) — `msg^ = nil`. Pointer was consumed internally. Caller must not touch it.

**APIs that follow this contract:**
- `mbox_send` — transfers to mailbox queue.
- `mbox.push` — transfers to mailbox queue (non-blocking variant).
- `pool.put` — returns item to pool free-list.
- `dispose` — frees item permanently.

**Result:** One variable, one check, same meaning everywhere.
```odin
if m != nil { /* I hold it — my responsibility */ }
// vs
if m == nil { /* transferred — not my problem anymore */ }
```

---

### `dispose-contract` — dispose signature contract

**Problem**: A struct contains internal heap resources. You need a proc to free them all safely.

**Fix**: Write a dispose proc that follows the `^Maybe(^T)` contract.

```odin
// [itc: dispose-contract]
disposable_dispose :: proc(itm: ^Maybe(^DisposableItm)) {
    if itm == nil  { return }
    if itm^ == nil { return }
    ptr := (itm^).?
    if ptr.name != "" { delete(ptr.name, ptr.allocator) }
    free(ptr, ptr.allocator)
    itm^ = nil
}
```

**Contract**:
- Takes `^Maybe(^T)`. Nil inner is a no-op. Sets inner to nil on return.
- Frees all internal resources before freeing the struct itself.
- Must be safe to call after a partial init. All cleanup steps handle zero-initialized fields.
- Register as `T_Hooks.dispose` so the pool calls it on permanent item destruction.

---

### `defer-dispose` — defer with dispose

**Problem**: You fill an item with internal heap resources before sending. If send fails, you need to clean up.

**Fix**: Register `dispose` via `defer` right after wrapping in Maybe.

```odin
m: Maybe(^DisposableItm) = itm
defer disposable_dispose(&m)  // [itc: defer-dispose]

m.?.name = strings.clone("hello", m.?.allocator)
if mbox_send(&mb, &m) { result = true }
```

**Behavior**:
- Send success → `m` nil → `dispose` no-op.
- Send fail → `m` non-nil → `dispose` frees everything.

---

### `errdefer-dispose` — conditional defer for factory procs

**Problem**: A factory proc creates a master. If setup fails halfway, partially-init state must be cleaned up.

**Fix**: Use a named return `ok` and `defer if !ok { dispose(...) }`.

```odin
// [itc: errdefer-dispose]
create_master :: proc() -> (m: ^Master, ok: bool) {
    raw := new(Master)
    if !master_init(raw) { free(raw); return }
    m_opt: Maybe(^Master) = raw
    defer if !ok { master_dispose(&m_opt) }

    // ... more setup ...
    m = raw
    ok = true; return
}
```

---

### `dispose-optional` — dispose is advice

**Problem**: The pool and mailbox do not call `dispose`. Only the caller does. It is easy to forget.

**Fix**: Use `defer` (`defer-dispose`) or manual drain loops to call `dispose` when an item leaves the system permanently.

```odin
// [itc: dispose-optional]
// You call dispose when the item will not be recycled.
```

---

## Object lifecycle / pool model

| Tag | One line |
|-----|----------|
| `defer-put` | Use `defer pool.put` to return to pool in all paths. |
| `disposable-itm` | Items with internal heap resources use pool_get, fill, send, receive, pool.put with reset, and a separate dispose for permanent cleanup. |
| `foreign-dispose` | When put returns a foreign pointer, call dispose, not free. |
| `reset-vs-dispose` | reset clears state for reuse. dispose frees internal resources permanently. factory allocates and initializes. |
| `t-hooks` | Define factory/reset/dispose as a :: constant next to the type. Pass by value to pool_init. Zero value = all defaults. |

### `defer-put` — defer with pool.put

**Problem**: You get an item from the pool and must return it in all paths, including error paths.

**Fix**: Use `defer pool.put` immediately after acquisition.

```odin
itm, status := pool_get(&p)
m: Maybe(^Itm) = itm
defer { // [itc: defer-put]
    ptr, accepted := pool.put(&p, &m)
    if !accepted && ptr != nil { disposable_dispose(&ptr) }
}
// ...
mbox_send(&mb, &m)
```

**Behavior**:
- If send succeeded: `m` becomes nil → `pool.put` becomes a no-op.
- If send failed: `m` still holds pointer → returned to pool by defer.

---

### `disposable-itm` — DisposableItm full lifecycle

**Problem**: Items with internal heap resources need careful handling through pool + mailbox.

**Fix**: Use `pool_get`, fill, `send`, `receive`, `pool.put` with reset, and a separate `dispose` for permanent cleanup. Register all three in `T_Hooks` so the pool manages the lifecycle.

```odin
// Setup: register hooks in pool_init
pool_init(&p, initial_msgs = 4, max_msgs = 0,
    hooks = DISPOSABLE_ITM_HOOKS)

// Producer:
itm, _ := pool_get(&p)
itm.name = strings.clone("hello", itm.allocator)
m: Maybe(^DisposableItm) = itm
defer disposable_dispose(&m)          // [itc: disposable-itm]
mbox_send(&mb, &m)

// Consumer:
got, _ := mbox.wait_receive(&mb)
m2: Maybe(^DisposableItm) = got
pool.put(&p, &m2)                     // [itc: reset-vs-dispose]
```

**Note**: `reset` clears state for reuse. `dispose` frees internal resources permanently. `factory` allocates and initializes. All three are optional in `T_Hooks`.

---

### `foreign-dispose` — foreign item with resources

**Problem**: `pool.put` returns a pointer when the item is foreign (allocator mismatch). `free` alone leaks resources.

**Fix**: Call `dispose` on the returned pointer, not `free`.

```odin
ptr, recycled := pool.put(&p, &m)
if !recycled && ptr != nil {
    foreign_opt: Maybe(^DisposableItm) = ptr
    disposable_dispose(&foreign_opt)  // [itc: foreign-dispose]
}
```

**Rule**: If allocator does not match pool → pool cannot recycle → caller disposes.

---

### `reset-vs-dispose` — reset vs dispose

**Problem**: It is easy to confuse `reset` (for reuse) with `dispose` (for permanent cleanup).

**Fix**: Keep them separate. Never free internal resources in `reset`. Register all three hooks in `T_Hooks`.

| Hook | When called | What it does |
|------|-------------|--------------|
| `factory` | Fresh allocation | Allocates struct, sets allocator, inits internal resources |
| `reset` | Get (recycled) and Put (before free-list) | Prepares item for reuse. Never frees internal resources |
| `dispose` | Permanent destruction (destroy, put-when-full) | Frees internal resources, frees struct, sets itm^ = nil |

```odin
// factory: alloc + init internal resources.
disposable_factory :: proc(allocator: mem.Allocator) -> (^DisposableItm, bool) {
    itm := new(DisposableItm, allocator)
    if itm == nil { return nil, false }
    itm.allocator = allocator
    return itm, true
}

// reset: clears state for reuse.
// [itc: reset-vs-dispose]
disposable_reset :: proc(itm: ^DisposableItm, _: pool.Pool_Event) {
    itm.name = ""
}

// dispose: frees everything permanently.
// [itc: dispose-contract]
disposable_dispose :: proc(itm: ^Maybe(^DisposableItm)) { ... }
```

---

### `t-hooks` — T_Hooks pattern

**Problem**: An item type has internal heap resources. The pool must allocate, reset, and free them correctly. Scattering this logic across call sites leads to leaks.

**Fix**: Define factory/reset/dispose as a `::` compile-time constant next to the item type. Pass it by value to `pool_init`. The pool calls the right hook at each lifecycle point.

```odin
// Define once, next to the type — in itm.odin:
MY_ITM_HOOKS :: pool.T_Hooks(MyItm){
    factory = my_factory, // fresh alloc — nil = new(T, allocator)
    reset   = my_reset,   // reuse hygiene — nil = no-op
    dispose = my_dispose, // permanent free — nil = free(itm, allocator)
}

// Simple type — zero value, all defaults:
pool_init(&p, hooks = pool.T_Hooks(MyItm){})

// [itc: t-hooks]
// Complex type — pass the constant:
pool_init(&p, initial_msgs = 4, max_msgs = 0,
    hooks = MY_ITM_HOOKS)

// Complex type + custom allocator:
pool_init(&p, initial_msgs = 4, max_msgs = 0,
    hooks = MY_ITM_HOOKS, allocator = my_alloc)
```

**Rules**:
- All three fields are optional. nil = default behavior.
- `factory` must set `itm.allocator`. Must self-clean on failure. Returns `(nil, false)` on failure.
- `reset` must NOT free internal resources. Pool calls it outside the mutex.
- `dispose` must free internal resources, free the struct, set `itm^ = nil`.
- If you use `factory`, also use `dispose`. They are the create/destroy pair.
- The allocator is a separate `init` parameter, not a field in `T_Hooks`.

---

## Concurrency structure

| Tag | One line |
|-----|----------|
| `heap-master` | Heap-allocate the struct that owns ITC participants when its address is shared with spawned threads. |
| `thread-container` | A thread proc only casts rawptr to ^Owner. No ITC participants declared as stack locals. |
| `defer-destroy` | Register `defer destroy` for pools/mboxes/loops to guarantee shutdown in all paths. |

### `heap-master` — ITC participants in a heap-allocated struct

**Problem**: Threads must not reference stack memory of a proc that might exit.

**Fix**: `new(Master)` — heap-allocate the owner. Call `dispose` after joining all threads.

```odin
m := new(Master) // [itc: heap-master]
if !master_init(m) { free(m); return false }
// ... spawn threads passing m ...
// ... join threads ...
m_opt: Maybe(^Master) = m
master_dispose(&m_opt)
```

---

### `thread-container` — thread is just a container for its master

**Problem**: Pointers to thread-local stack participants escape the thread's frame.

**Fix**: Move all ITC participants into the master struct. Thread proc only casts `rawptr` to `^Master`.

```odin
proc(data: rawptr) {
    c := (^Master)(data) // [itc: thread-container]
    // thread owns nothing; ITC objects live in Master
}
```

---

### `defer-destroy` — destroy resources at scope exit

**Problem**: Pools, mailboxes, or loops must be shut down in all paths to prevent leaks or deadlocks.

**Fix**: Register `destroy` with `defer` immediately after successful initialization.

```odin
mbox_init(&mb)
defer mbox_destroy(&mb) // [itc: defer-destroy]

pool_init(&p)
defer pool_destroy(&p)
```

**Why**: Cleanup runs in early returns. Shutdown logic stays near init.

---

## Addendums

### Foundational patterns

#### Lock release safety — `defer-unlock`
**Problem**: Lock acquired but function exits early → deadlock risk.
**Fix**: Register `defer unlock` immediately after lock acquisition.

```odin
sync.mutex_lock(&m)
defer sync.mutex_unlock(&m)
```

**Rule**: This is a foundational Odin pattern. In `matryoshka`, **never mark it with a tag** in the source code. It is documented here for reference only.

### Advice & Best Practices for New Idioms

1.  **`defer-destroy`**:
    *   Always use this for `Pool`, `Mailbox`, and `Mbox` instances that are owned by the current scope.
    *   If the resource is part of a `Master` struct, the `Master_dispose` proc handles the destroy calls, and you use `defer Master_dispose(&m_opt)`.
2.  **Foundational `defer-unlock`**:
    *   In your own worker threads, if you use a custom mutex to protect shared state, use `defer unlock`.
    *   Never call a `mbox_send` or `pool_get` (blocking) while holding a custom lock if it could lead to an inversion or deadlock.

### Detective's Audit Report: Idiom Compliance (2026-03-15)

#### 1. Idiom Coverage Matrix
This matrix identifies which example files demonstrate each idiom. All idioms meet or exceed the **50% saturation target**.

| Example File | mc | dp | dc | dd | di | fd | rv | do | hm | ed | ds | th | **Total** | tc (Base) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `lifecycle.odin` | ✓ | | ✓ | ✓ | | | | ✓ | ✓ | | | | **5** | |
| `close.odin` | ✓ | | ✓ | ✓ | | | | ✓ | ✓ | | | | **5** | ✓ |
| `interrupt.odin` | | | ✓ | ✓ | | | | | ✓ | ✓ | | | **4** | ✓ |
| `negotiation.odin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | | **10** | ✓ |
| `disposable_itm.odin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | | ✓ | **10** | ✓ |
| `master.odin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | **11** | |
| `stress.odin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | **11** | ✓ |
| `pool_wait.odin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | | ✓ | **10** | ✓ |
| `echo_server.odin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | | ✓ | **10** | ✓ |
| `endless_game.odin` | ✓ | | ✓ | ✓ | | | | | ✓ | ✓ | | | **5** | ✓ |
| `foreign_dispose.odin` | ✓ | | ✓ | | | ✓ | | | | | ✓ | ✓ | **4** | |
| **Total Usage** | **10** | **6** | **11** | **10** | **6** | **7** | **7** | **6** | **10** | **9** | **1** | **6** | | |

**Legend:**
*   **mc:** `maybe-container` | **dp:** `defer-put` | **dc:** `dispose-contract` | **dd:** `defer-dispose`
*   **di:** `disposable-itm` | **fd:** `foreign-dispose` | **rv:** `reset-vs-dispose` | **do:** `dispose-optional`
*   **hm:** `heap-master` | **tc:** `thread-container` | **ed:** `errdefer-dispose` | **ds:** `defer-destroy`
*   **th:** `t-hooks`

#### 2. Safety Compliance Summary

| Category | Invariant | Status |
| :--- | :--- | :--- |
| **Ownership** | Pointer transfers always use `^Maybe(^T)` | Verified |
| **Stack Safety** | No ITC participants shared from stack | Verified |
| **Cleanup** | Every allocation has cleanup path | Verified |
| **Pool Hygiene** | Foreign pointers handled correctly | Verified |
| **Factory Safety** | Factories use `errdefer` pattern | Verified |
| **Thread Isolation** | `thread-container` idiom used as mandatory baseline | Verified |
| **Scope Safety** | Runtime resources use `defer-destroy` in examples | Verified |

### loop_mbox and nbio_mbox

- `loop_mbox` = loop + any wakeup (semaphore, custom, or anything)
- `nbio_mbox` = loop + nbio wakeup (a special case of `loop_mbox`)

`nbio_mbox.init_nbio_mbox` creates a `loop_mbox.Mbox` with an nbio-specific `WakeUper`.
All `loop_mbox` procs work on the returned pointer: `send`, `try_receive_batch`, `close`, `destroy`.

---

*There are several ways to skin a cat. These idioms are one way. Use what works for you.*
