# Mailbox Design

## Overview

Two mailbox types. They solve different problems.

- `Mailbox($T)` — for worker threads. Blocks using a condition variable.
- `Loop_Mailbox($T)` — for nbio event loops. Non-blocking. Wakes the loop with `nbio.wake_up`.

---

## Comparison with `core:sync/chan`

Odin provides `core:sync/chan` for Go-style typed channels. `mbox` is a companion for specific technical needs.

| Feature | `core:sync/chan` | `mbox` |
|---|---|---|
| Allocation per message | yes — copies the value | zero — intrusive link |
| nbio integration | no | yes — `Loop_Mailbox` |
| Receive timeout | no | yes |
| Interrupt without close | no | yes — `interrupt()` (one-time signal) |
| Message ownership | channel owns the copy | caller owns memory; mailbox owns reference while queued |

---

## Internal storage

Both types use `core:container/intrusive/list` internally.

### What intrusive means

A normal list allocates a wrapper node for each item:

```odin
// The list allocates one of these per item (behind the scenes):
List_Node :: struct {
    next: ^List_Node,
    data: ^My_Msg,   // pointer to your data — two objects per message
}
```

An intrusive list does not allocate anything. The link lives inside your struct:

```odin
My_Msg :: struct {
    node: list.Node, // the link IS your struct — one object, zero allocation
    data: int,
}
```

- Zero allocations per message.
- You own the memory.
- Your struct must stay alive while it is in the list.

User struct contract:
- Must have a field named `node`.
- Type of `node` must be `list.Node` from `core:container/intrusive/list`.
- Field name is fixed. Not configurable.

```odin
import list "core:container/intrusive/list"

My_Msg :: struct {
    node: list.Node,  // required
    data: int,
}
```

The `where` clause on all procs enforces this at compile time:

```odin
where intrinsics.type_has_field(T, "node"),
      intrinsics.type_field_type(T, "node") == list.Node
```

If the struct does not have the right `node` field, the compiler gives an error.

### One place only

A `list.Node` can only be in one list at a time.
Do not send a message that is already queued somewhere else.
If the message is in another intrusive structure, call `list.remove` first.

While a message is in the mailbox, the mailbox owns the reference (the link).
When `close()` returns, the reference is handed back to the caller via the returned `list.List`.

---

## `Mailbox($T)` — worker thread mailbox

### Roles
- Sender: any thread.
- Receiver: worker thread or client thread.

### Behavior
- Many threads can send.
- One or many threads can receive.
- If empty, the receiver thread sleeps. The OS wakes it when a message arrives.
- Uses zero CPU while blocking.

### API
- `send(msg)` — adds message, signals one waiter.
- `wait_receive(timeout)` — blocks until message arrives, timeout, or interrupt. Use `timeout=0` for non-blocking poll.
- `interrupt()` — sends a one-time signal to wake one waiter with `.Interrupted`. Returns false if already interrupted or closed. Signal is automatically cleared on receipt.
- `close()` — blocks new sends, wakes all waiters with `.Closed`. Returns `(list.List, bool)` — remaining messages and whether this was the first close.

### Internal send pattern
```odin
list.push_back(&m.list, &msg.node)
m.len += 1
sync.cond_signal(&m.cond)
```

### Internal receive pattern
```odin
raw := list.pop_front(&m.list)
m.len -= 1
msg = container_of(raw, T, "node")
sync.cond_signal(&m.cond)   // wake next waiter if more messages remain
```

---

## `Loop_Mailbox($T)` — nbio loop mailbox

### Roles
- Sender: worker threads or client threads.
- Receiver: the nbio event loop thread only.

### Behavior
- Many threads can send.
- One receiver only — the nbio thread.
- The nbio thread never blocks inside the mailbox.
- It blocks only inside `nbio.tick()` or its wrappers like `nbio.run()` and `nbio.run_until()`.
- Synchronous OS calls like `nbio.open_sync()` also block.
- Every time a sender adds a message, it calls `nbio.wake_up` to interrupt the tick.

### API
- `send_to_loop(msg)` — adds message, calls `nbio.wake_up`.
- `try_receive_loop()` — returns one message. Never blocks. Call in a loop to drain.
- `close_loop()` — blocks new sends, calls `nbio.wake_up` once. Returns `(list.List, bool)` — remaining messages and whether this was the first close.
- `stats()` — message count. Not locked.

### Internal send pattern
```odin
list.push_back(&m.list, &msg.node)
m.len += 1
nbio.wake_up(m.loop)
```

---

## Key differences

| Feature | `Mailbox` | `Loop_Mailbox` |
|---|---|---|
| Thread type | Worker / client | nbio event loop |
| Wait method | `sync.cond_wait` | `nbio.tick` |
| Wake method | `sync.cond_signal` | `nbio.wake_up` |
| CPU when idle | zero | zero |
| Blocking receive | yes | no |

---

## Why two types?

- A blocking receive on the nbio thread would stop the event loop.
- `Loop_Mailbox` has no blocking receive. This prevents mistakes.
- Worker threads do not need `nbio.wake_up`. `Mailbox` is simpler for them.

---

## When to use which

- Use `Mailbox` for communication between worker threads.
- Use `Loop_Mailbox` to send commands to the nbio event loop.

---

## Best Practices

### 1. Ownership
Once a message is sent, do not read or write to it.
The mailbox owns the reference while it is queued.
You only get ownership back when you `receive()` it or get it from `close()`.

### 2. Shutdown
1. Call `close()` to signal all threads to stop.
2. `close()` returns all undelivered messages. You own these again and can safely free them.
3. Wait for all threads to finish (`thread.join()`) before freeing the mailbox itself.

### 3. Threads
Always wait for all threads to finish (`thread.join`) before you free the mailbox itself.
The mailbox must stay alive as long as any thread can still access it.

### 4. Message lifetime
Never use stack-allocated messages for inter-thread communication.
The stack frame can be freed before the receiving thread reads the message.

Three ownership patterns:

1. **Heap**: `new` to allocate, `free` after receive. Simple. Good for low-frequency use.
2. **Pool**: `pool.get` / `pool.put`. Reuse messages. No new allocations during the run.
3. **MASTER**: one struct owns both pool and mailbox. One shutdown call handles everything.

"Zero copies" means mbox does not copy message data. It does not mean zero allocations.
You still allocate message objects. mbox just links them.

### 5. nbio loop initialization
`Loop_Mailbox` must be initialized with `init_loop_mailbox(m, loop)`.
This sets up a hidden keepalive timer.
The timer ensures that `nbio.tick()` blocks in the kernel and listens for signals.
Without this, the loop might return immediately on some platforms (macOS, Windows).

---

## Ownership Transfer Pattern

### The Problem

Sending a message between threads transfers ownership.
After the send, the sender must not touch the message.
The receiver owns it.

Without a formal contract, two bugs are easy to make:

1. **Use-after-send.** Sender reads or writes the message after calling `send`. The receiver may already be modifying it.
2. **Leak on failed send.** `send` returns false (mailbox closed). Caller ignores the return value. Message is never freed.

### The Solution: `^Maybe(^T)`

Pass a pointer to an optional pointer. The callee zeroes the caller's variable on success.

```odin
// Before send — caller holds the message:
msg: Maybe(^Msg) = new(Msg)
msg.?.data = 42

// After send — msg is nil regardless of what the callee does with it:
mbox.send(&mb, &msg)
// msg == nil here — cannot reuse it
```

This is the Odin version of Zig's `*?*T` idiom.

### Type Breakdown

```
^  Maybe(^T)
^  ─────────
|  optional pointer — either a valid ^T or nil
pointer to that optional — passed to callee so it can zero the caller's variable
```

- `Maybe(^T)` — optional heap pointer. Either a valid `^T` or nil.
- `^Maybe(^T)` — pointer to that optional. This is what the API receives.
- After a successful call, the callee sets `msg^ = nil`. The caller's variable is nil.

**Syntax note.** `?^T` is not valid Odin. `^?^T` is also not valid. `^Maybe(^T)` is the only correct form.

### The Invariant

After any ownership-transferring call, the caller's variable is always `nil`.

This is true for every outcome except one: `send` on a closed mailbox.
In that case `msg^` is left unchanged — see the Closed Mailbox section below.

### Nil-Inner Is a No-Op

All functions accept `msg^ == nil`. They return early without doing anything.

This means cleanup code can call these functions unconditionally.
No need to check before calling.

```odin
// Safe — no-op if msg is already nil:
pool.put(&p, &msg)
pool.destroy_msg(&p, &msg)
mbox.send(&mb, &msg)
mpsc.push(&q, &msg)
```

### How We Check and Unwrap

Odin's two-value unwrap `val, ok := x.?` is one safe approach.
We use a different approach: nil-guard followed by single-value unwrap.

```odin
if msg^ == nil { return false }   // guard: handle nil case
ptr := (msg^).?                   // safe: already verified non-nil above
```

After the guard, `.?` on a non-nil `Maybe(^T)` cannot panic.
The guard doubles as the early-return for the nil no-op case, so no extra code is needed.

### Callee-Zeroing vs Caller-Zeroing

Some ownership patterns let the caller zero its own variable:

```odin
// Caller-managed:
ptr, ok := from.ptr.?
if !ok { return }
to.ptr   = ptr
from.ptr = nil   // caller zeroes its own variable
```

Our pattern lets the callee zero the caller's variable:

```odin
// Callee-managed (our pattern):
send :: proc(m: ^Mailbox($T), msg: ^Maybe(^T)) -> bool {
    if msg^ == nil { return false }
    ptr := (msg^).?
    // ... enqueue ptr ...
    msg^ = nil   // callee zeroes the caller's variable
    return true
}
```

Callee-managed is stronger. The caller has no opportunity to reuse the pointer after a successful call. There is no window between "send succeeded" and "pointer zeroed".

### The Four Functions

**`mpsc.push(q, msg: ^Maybe(^T)) -> bool`**

The lowest-level operation. Lock-free enqueue.

- `msg^ == nil` → returns false, no-op.
- Success → `msg^ = nil`, returns true.
- Never fails for any other reason (lock-free push always succeeds if msg is non-nil).

**`mbox.send(m, msg: ^Maybe(^T)) -> bool`**

Blocking mailbox send. Used by worker threads.

- `msg^ == nil` → returns false, no-op.
- Mailbox closed → returns false. `msg^` is **not** changed (see Closed Mailbox below).
- Success → `msg^ = nil`, returns true. Wakes one waiting receiver.

**`try_mbox.send(m, msg: ^Maybe(^T)) -> bool`**

Non-blocking mailbox send. Used by producers sending to an nbio loop.
Delegates directly to `mpsc.push`. Same semantics as `mbox.send`.

**`pool.put(p, msg: ^Maybe(^T)) -> (^T, bool)`**

Returns a message to the pool's free-list.

- `msg^ == nil` → returns `(nil, true)`, no-op.
- Own message (message allocator matches pool allocator) → `msg^ = nil`, message recycled, returns `(nil, true)`.
- Foreign message (allocator differs) → `msg^ = nil`, returns `(ptr, false)`. Caller must free `ptr`.
- Pool closed or full → `msg^ = nil`, message freed internally, returns `(nil, true)`.

The second return value tells the caller whether the message was accepted.
`false` means caller must free the returned pointer.
`true` means the pool handled it; caller does nothing.

### Why `pool.put` Returns `(^T, bool)`

The pool stores messages allocated with its own allocator.
If a message was allocated elsewhere (different allocator), the pool cannot recycle it.

The pool still zeroes `msg^` to uphold the invariant — the caller's variable is always nil.
It returns the raw pointer so the caller can free it with the correct allocator.

```odin
foreign_ptr, accepted := pool.put(&p, &msg)
// msg is nil in both cases
if !accepted {
    free(foreign_ptr, my_allocator)
}
```

### The Closed Mailbox Path

`mbox.send` and `try_mbox.send` return false when the mailbox is closed.
In this case, `msg^` is left unchanged.

This is intentional. `send` has no allocator reference.
It cannot free the message even if it wanted to.
Only the caller knows whether the message came from a pool, the heap, or a custom allocator.

The caller must check the return value:

```odin
ok := mbox.send(&mb, &msg)
if !ok {
    // msg^ is still non-nil — we own it, must free it
    pool.destroy_msg(&p, &msg)   // if from pool
    // or: free(msg.?, my_allocator) if from heap
    msg = nil
}
```

Ignoring a false return silently leaks the message.

### `pool.destroy_msg` — The Error-Path Helper

Called when `send` fails and the unsent message must be freed.

```odin
destroy_msg :: proc(p: ^Pool($T), msg: ^Maybe(^T))
```

- `msg^ == nil` → no-op.
- Otherwise → `free(msg^, p.allocator)`, `msg^ = nil`.

Use this when your messages come from the pool and `send` returns false.

### Caller Lifecycle

```
pool.get(&p)                     → caller gets ^T

msg: Maybe(^T) = ptr             → wrap before passing to send/push

ok := mbox.send(&mb, &msg)
  ok == true  → msg is nil, mailbox owns the message
  ok == false → msg is still non-nil, send failed (closed)
                → pool.destroy_msg(&p, &msg)   free and nil

ok := try_mbox.send(m, &msg)     → same as above

foreign, ok := pool.put(&p, &msg)
  ok == true  → msg is nil, pool recycled or freed the message
  ok == false → msg is nil, but foreign != nil — caller frees foreign

pool.destroy_msg(&p, &msg)       → msg is nil, message freed
                                    safe to call if msg is already nil
```

### What Does NOT Use This Pattern

These functions return a message to the caller. Ownership goes the other way.

- `mbox.wait_receive` — gives `^T` to caller.
- `try_mbox.try_receive_batch` — gives `list.List` to caller.
- `pool.get` — gives `^T` to caller.
- `mbox.close` — gives `list.List` to caller.
- `mbox.interrupt` — no message involved.

### Connection to the Intrusive List

The intrusive list stores the `node` field directly inside your struct.
No wrapper allocation. The message IS the node.

`^Maybe(^T)` completes the picture:

- Intrusive list = zero copies while queued (no wrapper, no copy of data).
- `^Maybe(^T)` = zero-ambiguity ownership transfer (caller's variable is nil after send).

Together: one heap allocation per message, zero copies, zero aliasing after transfer.

### Pool Allocator Field

`pool.put` compares `ptr.allocator` with `p.allocator` to detect foreign messages.
This requires T to have an `allocator: mem.Allocator` field.

`pool.get` sets `msg.allocator = p.allocator` on every returned message.
This is what makes the comparison reliable.

```odin
Msg :: struct {
    node:      list.Node,        // required by mailbox
    allocator: mem.Allocator,    // required by pool
    data:      int,
}
```

Both fields are enforced at compile time by the `where` clause on all pool procs.

### Common Mistakes

**Mistake 1: reuse after send**
```odin
msg: Maybe(^Msg) = new(Msg)
msg.?.data = 1
mbox.send(&mb, &msg)
msg.?.data = 2   // WRONG — msg is nil, this panics
```

**Mistake 2: ignore false return**
```odin
mbox.send(&mb, &msg)   // WRONG — return value ignored
// if send returned false, msg is non-nil and leaking
```

**Mistake 3: send a stack message**
```odin
local: Msg
local.data = 1
msg: Maybe(^Msg) = &local
mbox.send(&mb, &msg)   // WRONG — &local points to the stack
// the stack frame will be freed; receiver reads garbage
```
Always allocate with `new` or `pool.get`.

**Mistake 4: double free**
```odin
msg: Maybe(^Msg) = new(Msg)
mbox.send(&mb, &msg)
free(msg.?)   // WRONG — msg is nil after send, .? panics
```
Only free if `send` returned false (msg^ is still non-nil).

---

## Long story short

The pattern uses ^Maybe(^T) (Odin's equivalent of Zig's *?*T) to make thread ownership transfer unambiguous and safe.

  Core idea: Pass a pointer-to-optional to the callee. On success, the callee zeroes the caller's variable. After any successful send/push/put, the
  caller's pointer is nil — it cannot accidentally reuse it.

  Key rules:
  - msg^ == nil on input → always a no-op, safe to call unconditionally in cleanup
  - Success → callee sets msg^ = nil, returns true
  - mbox.send on closed mailbox → returns false, msg^ unchanged (caller still owns it, must free)
  - Only correct Odin syntax is ^Maybe(^T) — ?^T and ^?^T are invalid

  Four affected functions: mpsc.push, mbox.send, try_mbox.send, pool.put

  One exception: pool.put returns (^T, bool) — if message is "foreign" (different allocator), it zeroes msg^ but returns the raw pointer so caller
  can free it with the right allocator.

  Error helper: pool.destroy_msg — call when send returns false; frees the unsent message and nils msg^.

  What does NOT use this pattern: receive-side functions (wait_receive, try_receive_batch, pool.get, mbox.close) — they give ownership TO the
  caller, not take it away.

---

## Nil on Input — Behavior Summary

| Function | nil guard | returns | `msg^` after |
|---|---|---|---|
| `mpsc.push` | `if msg^ == nil { return false }` | `false` | unchanged (nil) |
| `mbox.send` | `if msg^ == nil { return false }` | `false` | unchanged (nil) |
| `try_mbox.send` | `if msg^ == nil { return false }` | `false` | unchanged (nil) |
| `pool.put` | `if msg^ == nil { return nil, true }` | `(nil, true)` | unchanged (nil) |

---

## Non-Nil on Input — Behavior Summary

| Function | condition | returns | `msg^` after |
|---|---|---|---|
| `mpsc.push` | non-nil (always succeeds) | `true` | `nil` |
| `mbox.send` | closed | `false` | unchanged (caller retains ownership) |
| `mbox.send` | success | `true` | `nil` |
| `try_mbox.send` | closed | `false` | unchanged (caller retains ownership) |
| `try_mbox.send` | success | `true` | `nil` |
| `pool.put` | foreign message (allocator differs) | `(ptr, false)` | `nil` — caller must free returned `ptr` |
| `pool.put` | own message, pool closed or full | `(nil, true)` | `nil` — pool freed it internally |
| `pool.put` | own message, pool active | `(nil, true)` | `nil` — recycled to free-list |

Key observations:
- `mpsc.push` has only one non-nil outcome — it always succeeds.
- `mbox.send` and `try_mbox.send` are symmetric: closed leaves `msg^` intact, success nils it.
- `pool.put` has three outcomes, all nil `msg^`, but only the foreign case requires caller action (free the returned pointer).

---

## Zig and Odin: The Same Pattern in Two Languages

Both Zig and Odin arrived at the same design for ownership transfer.
Neither has a borrow checker. Both solve the problem with a pointer-to-optional idiom.

### The Shared Problem

Sending a pointer between threads transfers ownership.
After the call, the sender must not touch the pointer.
Without language-level enforcement, two bugs are common:

- Use-after-send: sender reads or modifies the message the receiver now owns.
- Leak-on-failure: send fails (channel closed), return value ignored, message never freed.

Neither Zig nor Odin can stop these at compile time the way Rust can.
Both instead use a convention that makes the bugs obvious at the call site.

### Zig: `*?*T`

Zig's type system distinguishes non-nullable and nullable pointers:

- `*T` — pointer, NEVER null. The compiler enforces this. Dereferencing is always safe.
- `?*T` — optional pointer. May be null. Must be checked before use.
- `*?*T` — pointer to an optional pointer. Callee sets `msg.* = null` after consuming.

```zig
pub fn put(ampe: Ampe, msg: *?*message.Message) void {
    if (msg.* == null) return;   // nil inner — no-op
    msg.*.?.reset();
    ampe.vtable.put(ampe.ptr, msg);  // impl sets msg.* = null
}

pub fn post(chnls: ChannelGroup, msg: *?*message.Message) !message.BinaryHeader {
    return chnls.vtable.post(chnls.ptr, msg);  // on success: msg.* = null
}
```

After `put` or `post`, `msg.*` is null. The caller's variable cannot be reused.

Zig's `value.?` (unwrap) is `value orelse unreachable`.
In Debug/ReleaseSafe builds: panics if null.
In ReleaseFast/ReleaseSmall builds: undefined behavior if null. Use with care.

### Odin: `^Maybe(^T)`

Odin does not distinguish non-nullable and nullable at the pointer type level.
`^T` can be nil. Nothing stops you at compile time.

`Maybe(^T)` is defined as `union($T: typeid) { T }` — a union with one pointer variant.
The tag is omitted (tag-free layout). Nil means absent. Non-nil means present.
This is the same semantic as Zig's `?*T`, just expressed differently.

- `Maybe(^T)` — optional pointer. Either a valid `^T` or nil.
- `^Maybe(^T)` — pointer to that optional. Callee sets `msg^ = nil` after consuming.

```odin
put :: proc(p: ^Pool($T), msg: ^Maybe(^T)) -> (^T, bool) {
    if msg^ == nil { return nil, true }  // nil inner — no-op
    ptr := (msg^).?
    // ... recycle ptr ...
    msg^ = nil
    return nil, true
}

send :: proc(m: ^Mailbox($T), msg: ^Maybe(^T)) -> bool {
    if msg^ == nil { return false }
    ptr := (msg^).?
    // ... enqueue ptr ...
    msg^ = nil
    return true
}
```

After `put` or `send`, `msg` is nil. The caller's variable cannot be reused.

Odin's `value.?` (single-value unwrap) panics if nil in ALL build modes.
The two-value form `val, ok := value.?` never panics.

### Syntax Side by Side

| Concept | Zig | Odin |
|---|---|---|
| Non-null pointer | `*T` (compiler enforced) | `^T` (convention only) |
| Optional pointer | `?*T` | `Maybe(^T)` |
| Pointer to optional | `*?*T` | `^Maybe(^T)` |
| Dereference optional | `msg.*.?` | `(msg^).?` |
| Set to null | `msg.* = null` | `msg^ = nil` |
| Check null | `msg.* == null` | `msg^ == nil` |
| Unwrap (safe) | `if (msg.*) \|ptr\| { ... }` | `val, ok := (msg^).?` |
| Unwrap (panic if nil) | `msg.*.?` (UB in ReleaseFast) | `(msg^).?` (panics always) |
| Invalid syntax | — | `?^T`, `^?^T` |

### Key Differences

**Null safety at the type level.**
Zig: `*T` is provably non-null. The compiler rejects null assignment.
Odin: `^T` may be null. No compile-time check. `Maybe(^T)` adds intent but not enforcement.

This means in Zig the pattern is backed by the type system more deeply.
In Odin, `Maybe(^T)` is a strong convention. The compiler checks the union type at call sites but cannot prevent passing a nil `^T` directly.

**Unwrap safety.**
Zig: `.?` is `orelse unreachable` — UB in optimized builds if nil.
Odin: `.?` panics consistently in all build modes. More predictable.

**Error handling.**
Zig uses error unions (`!T`) as a first-class language feature.
Zig's `try` keyword propagates errors automatically.
Odin uses multiple return values. Explicit but more verbose.

**Generics.**
Zig uses `comptime` — the entire type system is available at compile time.
Odin uses `$T: typeid` for parametric types and `where` clauses for constraints.
Both enforce struct layout requirements at compile time.

**Nil-inner no-op.**
Both implementations accept a nil inner as a no-op.
Neither requires a pre-call nil check from the caller.
Cleanup code can call put/send unconditionally.

### Compared to Other Languages

**Rust.**
Rust moves values at compile time. After `channel.send(msg)`, `msg` is moved — the compiler refuses any further use of the variable. No runtime check needed. The transfer is zero-cost and provably correct.
Zig and Odin achieve the same runtime behavior but without compile-time proof.

**Go.**
Go channels copy values into a buffer. No pointer ownership question arises.
The sender keeps its copy. The channel sends a separate copy to the receiver.
This is simpler but uses more memory for large messages.
Zig and Odin send the pointer — one allocation, zero copies.

**C++.**
`std::unique_ptr` with `std::move` is the closest equivalent.
After `std::move(ptr)`, the source is null. The compiler warns on use-after-move in some cases.
But `unique_ptr` carries heap overhead and does not integrate with intrusive lists.

**C.**
No enforcement. Convention only. Common source of use-after-free bugs in message-passing C code.

### What the Pattern Gives You

Without a borrow checker, in a language where pointers can be nil:

- One allocation per message.
- Zero copies during transfer.
- Caller's variable is nil after a successful call — use-after-send panics immediately.
- Nil-inner as no-op — safe to call unconditionally in cleanup.

The pattern does not give you compile-time proof of correctness.
It gives you runtime predictability: bugs are loud (nil dereference panics), not silent (stale pointer reads).

### Origin

This pattern was ported from the Zig `mailbox` and `ampe` implementations:

- `/home/g41797/dev/root/github.com/g41797/mailbox/src/mailbox.zig`
- `/home/g41797/dev/root/github.com/g41797/tofu/src/ampe.zig`

In Zig: `put`, `post`, and `updateReceiver` all take `*?*message.Message`.
In Odin: `put`, `send`, `push` all take `^Maybe(^T)`.

Same problem. Same solution. Different syntax.

---

## Pool Design

### Overview

A pool is a thread-safe free-list of reusable message objects.

The mailbox moves messages between threads. The pool gives them back to be reused.

Without a pool, every send requires a `new` and every receive requires a `free`.
With a pool, the same objects travel in a cycle: get → send → receive → put → get → ...

No new allocations during the run. No GC pressure.

---

### Stage 1 — Simple Pool

The basic idea: keep a list of pre-allocated messages. Hand them out. Take them back.

```
init   → pre-allocate N messages, put them in the free-list
get    → pop one message from the free-list
           free-list empty + .Always strategy → allocate a new one
put    → push the message back onto the free-list
destroy → free all messages still in the free-list
```

#### API

- `init(initial_msgs, ...)` — pre-fills the free-list. `initial_msgs = 0` is valid (start empty).
- `get(strategy) -> (^T, Pool_Status)` — returns a message. Two strategies:
  - `.Always` (default) — allocates a new message if the free-list is empty.
  - `.Pool_Only` — returns `(nil, .Pool_Empty)` if the free-list is empty.
- `put(msg: ^Maybe(^T)) -> (^T, bool)` — returns a message to the free-list. Uses the ownership transfer pattern (see above).
- `destroy()` — frees all free-list messages and marks the pool closed.

#### Lifecycle states

| State | Meaning |
|---|---|
| `Uninit` | `init` not yet called |
| `Active` | running — `get` and `put` work |
| `Closed` | `destroy` was called — `get` returns `(nil, .Closed)` |

#### reset hook

`init` accepts an optional `reset` proc:
```odin
reset: proc(msg: ^T, e: Pool_Event)
```

Called outside the mutex:
- On `get`: called for recycled messages only (not fresh allocations). Use it to wipe stale state before the caller gets the message.
- On `put`: called before the message goes back to the free-list. Use it to detect stale pointers early.

`Pool_Event` tells the hook which path triggered it: `.Get` or `.Put`.

---

### Stage 2 — Count Limit and Get Timeout

#### Count limit

`init` accepts `max_msgs`. This caps the free-list size.

When `put` is called and `curr_msgs >= max_msgs`, the message is freed instead of recycled.
The caller's variable is still nilled. The call still returns `(nil, true)`.

`max_msgs = 0` means unlimited.

#### Get timeout

Useful with `.Pool_Only`. The caller does not want to allocate — only reuse.

`get(strategy: .Pool_Only, timeout)` blocks if the free-list is empty:

| timeout | behavior |
|---|---|
| `0` | return immediately with `(nil, .Pool_Empty)` |
| `< 0` | wait forever until `put` or `destroy` |
| `> 0` | wait up to that duration; return `(nil, .Pool_Empty)` on expiry |

When `destroy` is called while a caller is waiting, the caller wakes and gets `(nil, .Closed)`.

---

### Stage 3 — WakeUper

`Mailbox` uses a condition variable to wake blocked receivers.
`Pool` uses the same mechanism for blocked `get(.Pool_Only)` calls.

But a non-blocking consumer (nbio event loop) cannot block inside `get`.
It calls `get(.Pool_Only, 0)`, gets `Pool_Empty`, and needs to know when to try again.

That is what the `WakeUper` is for.

#### How it works

`init` accepts a `waker: wakeup.WakeUper` (zero value = no waker).

When `get(.Pool_Only, 0)` returns `Pool_Empty`, the pool sets an internal flag `empty_was_returned`.

When the next `put` transitions the free-list from empty to non-empty AND the flag is set:
- `put` clears the flag.
- `put` calls `waker.wake` outside the mutex.

The waker signals the consumer to retry `get`.

This is a one-shot signal per empty→non-empty transition. Multiple `put` calls in a row produce one wake, not many.

#### destroy and waker

`destroy` calls `waker.close` to free waker resources.
It does NOT call `waker.wake`. Callers polling with `get(.Pool_Only, 0)` will get `(nil, .Closed)` on the next call.

---

### Requirements for the Message Object

Pool adds one requirement on top of what `Mailbox` already needs.

| Field | Type | Required by | Purpose |
|---|---|---|---|
| `node` | `list.Node` | mailbox + pool | intrusive list link |
| `allocator` | `mem.Allocator` | pool only | detect foreign messages in `put` |

`pool.get` sets `msg.allocator = p.allocator` on every returned message.
`pool.put` compares `ptr.allocator` with `p.allocator` to detect foreign messages.

A foreign message (allocator differs) is not recycled. `put` returns `(ptr, false)` and the caller frees it.

Both fields are enforced at compile time by `where` clauses on all pool procs.

```odin
Msg :: struct {
    node:      list.Node,     // required by mailbox and pool
    allocator: mem.Allocator, // required by pool
    data:      int,
}
```

---

### Examples

#### Basic: heap fallback

```odin
p: pool.Pool(Msg)
pool.init(&p, initial_msgs = 4, max_msgs = 0, reset = nil)
defer pool.destroy(&p)

// producer
msg, status := pool.get(&p)   // from free-list or heap
if status != .Ok {
    // handle allocation failure
}
m: Maybe(^Msg) = msg
m.?.data = 42
ok := mbox.send(&mb, &m)
if !ok {
    pool.destroy_msg(&p, &m)   // mailbox closed — free the unsent message
}

// consumer
got, _ := mbox.wait_receive(&mb)
// use got.data
m2: Maybe(^Msg) = got
_, accepted := pool.put(&p, &m2)   // back to free-list
if !accepted {
    // got was foreign — free with correct allocator
}
```

#### Pool-only with timeout

```odin
// blocks up to 100ms; returns Pool_Empty if nothing available
msg, status := pool.get(&p, .Pool_Only, 100 * time.Millisecond)
if status != .Ok {
    // no message available
}
```

#### Error path: send failed

```odin
msg, _ := pool.get(&p)
m: Maybe(^Msg) = msg
ok := mbox.send(&mb, &m)
if !ok {
    // mailbox closed — m is still non-nil, we own it
    pool.destroy_msg(&p, &m)   // free and nil
}
```

#### Foreign message in put

```odin
msg := new(Msg, other_allocator)
m: Maybe(^Msg) = msg
ptr, accepted := pool.put(&p, &m)
// m is nil in both cases
if !accepted {
    free(ptr, other_allocator)
}
```

This is correct when `Msg` has no dynamic resources inside.

If `Msg` contains heap fields (slices, strings, handles), `free` alone is not enough.
It leaks the internal resources.

A `Msg` with internal resources should have its own `destroy` proc.
The `destroy` proc frees internal resources first, then frees the struct itself.

```odin
// Msg with internal resources:
Msg :: struct {
    node:      list.Node,
    allocator: mem.Allocator,
    name:      string,   // heap-allocated
}

msg_destroy :: proc(msg: ^Msg) {
    delete(msg.name, msg.allocator)   // free internal resources first
    free(msg, msg.allocator)          // then free the struct
}
```

The caller uses `msg_destroy` instead of raw `free`:

```odin
if !accepted {
    msg_destroy(ptr)   // handles everything
}
```

Rule: `free` alone is only correct for plain data structs.
A `Msg` with internal resources must have a `destroy` proc.
The pool cannot know what is inside. Only the caller can.

#### Similarity with Mailbox

Both mailbox and pool:
- Use intrusive lists. No allocation per operation.
- Use `^Maybe(^T)` for ownership transfer (`send`, `put`, `push`).
- Use `close`/`destroy` to shut down and wake blocked callers.
- Use `WakeUper` to notify non-blocking consumers.

The difference:
- Mailbox moves messages from sender to receiver.
- Pool moves messages from consumer back to producer.

They work together. One message object travels the full cycle.

---

## Idioms

Collected patterns and advice. Each has come up across the design.

---

### The two silent bugs

Before any idioms: the two bugs these patterns prevent.

**Bug 1: use-after-send.**

```odin
// WRONG
ptr := new(Msg)
ptr.data = 1
mbox.send(&mb, ptr)   // old API — takes ^T, not ^Maybe(^T)
ptr.data = 2          // receiver may already own this
```

After `send`, the receiver owns the message.
The sender must not read or write it.
There is no compiler error. The race is silent.

**Bug 2: leak on failed send.**

```odin
// WRONG
ptr := new(Msg)
mbox.send(&mb, ptr)   // return value ignored
// if send returned false (closed), ptr leaks — forever
```

`send` returns false when the mailbox is closed.
Ignoring the return value leaks the message.
No crash. No warning. Silent leak.

---

### Idiom 1: Maybe as container

**Problem:** after `send`, the pointer must be gone from the sender.
The caller cannot enforce this on itself.

**Fix:** wrap in `Maybe`. The callee zeroes the caller's variable.

```odin
m: Maybe(^Msg) = new(Msg)   // declare as Maybe from the start
m.?.data = 42               // fill via .?
ok := mbox.send(&mb, &m)    // callee sets m = nil on success
// m is nil — cannot reuse, cannot double-free
```

Rule: declare `m: Maybe(^Msg) = new(...)`, fill via `m.?.field`, pass `&m`.
One owner from the start. No intermediate raw pointer.

Exception: keep a raw pointer only when a helper proc requires `^Msg`.

---

### Idiom 2: defer with pool.put

**Nil inner is a no-op.** If send succeeds, `m` is nil before `defer` fires.
`pool.put` with nil inner returns `(nil, true)` immediately.

```odin
msg, _ := pool.get(&p)
m: Maybe(^Msg) = msg
defer pool.put(&p, &m)      // safe: no-op if send already transferred ownership

ok := mbox.send(&mb, &m)
if !ok {
    // defer will handle cleanup — or call destroy_msg here explicitly
}
```

`defer pool.put(&p, &m)` is safe in all paths:
- send succeeded → `m` is nil → put is a no-op.
- send failed → `m` is non-nil → put recycles or frees.

---

### Idiom 3: dispose signature contract

`dispose` must accept `^Maybe(^T)`, not `^T`.
It must treat nil inner as a no-op.

This is the same contract as `pool.put` and `mbox.send`.

```odin
dispose :: proc(msg: ^Maybe(^DisposableMsg)) {
    if msg^ == nil { return }      // nil inner — no-op
    ptr := (msg^).?
    delete(ptr.name, ptr.allocator)
    free(ptr, ptr.allocator)
    msg^ = nil
}
```

Without this contract, `defer dispose(&m)` is not safe:
if send already transferred ownership and `m` is nil, a raw-pointer dispose would dereference nil.

---

### Idiom 4: defer with dispose

Works only when `dispose` follows the `^Maybe(^T)` contract above.

```odin
m: Maybe(^DisposableMsg) = new(DisposableMsg)
defer dispose(&m)               // safe: no-op if m is nil

m.?.name = strings.clone("hello")
ok := mbox.send(&mb, &m)
// if ok: m is nil, defer is a no-op
// if !ok: m is non-nil, defer calls dispose
```

Pattern: allocate, set up resources, defer dispose, then send.
If send fails for any reason, defer cleans up.

---

### Idiom 5: DisposableMsg — full lifecycle

A message with internal heap resources needs two things:
- `dispose` — final cleanup when the message is done.
- optionally `reset` — hygiene when the message is reused via pool.

```odin
DisposableMsg :: struct {
    node:      list.Node,
    allocator: mem.Allocator,
    name:      string,          // heap-allocated
}

// Called by pool.get (before handing to caller) and pool.put (before free-list).
// Clears stale fields. Does NOT free internal resources.
disposable_reset :: proc(msg: ^DisposableMsg) {
    msg.name = ""   // clear stale reference — pool may reuse this slot
}

// Called by the caller when the message is permanently done.
// Frees all internal resources, then frees the struct.
dispose :: proc(msg: ^Maybe(^DisposableMsg)) {
    if msg^ == nil { return }
    ptr := (msg^).?
    delete(ptr.name, ptr.allocator)   // free internal resources first
    free(ptr, ptr.allocator)          // then free the struct
    msg^ = nil
}
```

Full lifecycle:

```odin
// get from pool — reset runs automatically
msg, _ := pool.get(&p)
m: Maybe(^DisposableMsg) = msg
defer dispose(&m)

m.?.name = strings.clone("hello", m.?.allocator)
ok := mbox.send(&mb, &m)
// defer handles cleanup if send failed
```

Receiver:

```odin
got, _ := mbox.wait_receive(&mb)
// use got.name
m2: Maybe(^DisposableMsg) = got
_, accepted := pool.put(&p, &m2)   // reset runs automatically on put
if !accepted {
    // foreign message — must dispose manually
    dispose(&m2)
}
```

---

### Idiom 6: foreign message with resources

`pool.put` returns `(ptr, false)` when the message allocator differs from the pool allocator.

If the message has internal resources, `free` alone leaks them.

```odin
// WRONG — leaks name
if !accepted {
    free(ptr, other_allocator)
}

// CORRECT
if !accepted {
    dispose(&m)   // or msg_destroy(ptr) — frees resources, then struct
}
```

Use `dispose` (or `msg_destroy`) instead of raw `free` when the message has resources.

---

### Idiom 7: reset vs dispose

Two different cleanup concerns.

**`reset`** — message stays alive. It is being recycled.

- Pool calls it automatically: on `get` before handing to caller, on `put` before free-list.
- Use it to zero stale fields or close/reopen handles for reuse.
- Does NOT free internal resources. Does NOT free the struct.
- About **reuse hygiene**.

**`dispose`** — message is done. Release everything.

- Caller calls it. Pool and mailbox never call it.
- Frees internal resources in order, then frees the struct.
- About **final cleanup**.

A `DisposableMsg` may need both: `reset` to refresh on reuse, `dispose` when permanently discarded.

```odin
// reset: called on every pool cycle — zero stale state
disposable_reset :: proc(msg: ^DisposableMsg) {
    msg.name = ""   // clear — do not delete, pool will reuse slot
}

// dispose: called once, when message is done
dispose :: proc(msg: ^Maybe(^DisposableMsg)) {
    if msg^ == nil { return }
    ptr := (msg^).?
    delete(ptr.name, ptr.allocator)
    free(ptr, ptr.allocator)
    msg^ = nil
}
```

---

### Idiom 8: dispose is advice, not a requirement

Pool and mailbox enforce two fields at compile time:

| | `node` | `allocator` | `dispose` |
|---|---|---|---|
| Required by code | yes | yes (pool only) | no |
| Who needs it | mailbox + pool | pool | caller, when message has resources |
| Enforced by | `where` clause | `where` clause | convention only |

Key points:

- Pool and mailbox enforce `node` and `allocator` because they need them to work.
- `dispose` is different. Pool and mailbox do not know what is inside a message. They never call `dispose`.
- Not every message needs `dispose`. A message with no internal resources needs nothing extra.
- Resource cleanup is the caller's responsibility. `dispose` is the pattern to follow when the message owns resources beyond memory.
- Memory is the last resource to release. File handles, sockets, and other OS resources must be closed first.
- This is the Odin equivalent of a destructor — built by convention, not enforced by the compiler.

Two examples side by side:

```odin
// Plain data — no dispose needed.
// pool.put or pool.destroy_msg is enough.
Msg :: struct {
    node:      list.Node,
    allocator: mem.Allocator,
    data:      int,
}

// Message with resources — define dispose.
DisposableMsg :: struct {
    node:      list.Node,
    allocator: mem.Allocator,
    name:      string,   // heap-allocated — must be freed before struct
}

dispose :: proc(msg: ^Maybe(^DisposableMsg)) {
    if msg^ == nil { return }
    ptr := (msg^).?
    delete(ptr.name, ptr.allocator)
    free(ptr, ptr.allocator)
    msg^ = nil
}
```
