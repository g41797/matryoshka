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
