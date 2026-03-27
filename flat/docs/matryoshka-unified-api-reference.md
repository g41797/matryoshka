# matryoshka — Unified API Reference

> One ownership model for everything.
> Data and infrastructure follow the same rules.

---

## Core Types

### PolyNode

The header at **offset 0** in every item.

```odin
PolyNode :: struct {
    using node: list.Node,
    id:         int, // must be != 0
}
````

All items — user data and infrastructure — embed this first.

---

### Maybe(^PolyNode)

The ownership handle.

* `m^ == nil` → not yours
* `m^ != nil` → yours

You must:

* transfer it
* or dispose it

---

## ID Rules

One field.
Two ranges.

```odin
// Convention
id == 0   → invalid
id > 0    → user data
id < 0    → infrastructure
```

Example:

```odin
SystemId :: enum int {
    Invalid = 0,
    Mailbox = -1,
    Pool    = -2,
}
```

User must not use negative ids.

---

## Lifecycle

No central factory.

Create directly.
Dispose through one entry.

All infrastructure items store their allocator internally.

---

### Creation

```odin
mbox_new :: proc(alloc: mem.Allocator) -> Mailbox
pool_new :: proc(alloc: mem.Allocator) -> Pool
```

---

### Disposal

```odin
matryoshka_dispose :: proc(m: ^Maybe(^PolyNode))
```

Entry:

| Condition   | Result |
| ----------- | ------ |
| `m == nil`  | no-op  |
| `m^ == nil` | no-op  |

Algorithm:

* read `m^.id`
* cast to internal type
* check state

| State  | Action      |
| ------ | ----------- |
| closed | free memory |
| open   | panic       |

Exit:

* `m^ = nil` on success

---

## Mailbox API

Moves ownership between threads.

---

### Handle

```odin
Mailbox :: distinct ^PolyNode
```

---

### Operations

```odin
SendResult :: enum {
    Ok,
    Closed,
    Invalid,
}

mbox_send :: proc(mb: Mailbox, m: ^Maybe(^PolyNode)) -> SendResult

RecvResult :: enum {
    Ok,
    Closed,
    Interrupted,
    Already_In_Use,
    Invalid,
    Timeout,
}

mbox_wait_receive :: proc(
    mb: Mailbox,
    out: ^Maybe(^PolyNode),
    timeout: time.Duration = -1,
) -> RecvResult

IntrResult :: enum {
    Ok,
    Closed,
    Already_Interrupted,
}

mbox_interrupt :: proc(mb: Mailbox) -> IntrResult

// Marks mailbox closed.
// Wakes all waiters.
// Returns remaining items. Caller must drain.
mbox_close :: proc(mb: Mailbox) -> list.List

// Non-blocking drain of currently available items.
try_receive_batch :: proc(mb: Mailbox) -> list.List
```

---

### Ownership rules

Send:

| Result | `m^` after |
| ------ | ---------- |
| `.Ok`  | nil        |
| other  | unchanged  |

Receive:

| Result | `out^` after |
| ------ | ------------ |
| `.Ok`  | non-nil      |
| other  | unchanged    |

---

### Notes

* Mailbox is an item
* Mailbox can be sent
* Mailbox must be closed before dispose

---

## Pool API

Provides reuse and policy.

---

### Handle

```odin
Pool :: distinct ^PolyNode
```

---

### Initialization

```odin
pool_init :: proc(p: Pool, hooks: ^PoolHooks)
```

Hooks must outlive the pool.

---

### Operations

```odin
pool_close :: proc(p: Pool) -> (list.List, ^PoolHooks)

Pool_Get_Mode :: enum {
    Available_Or_New,  // use stored item or create
    New_Only,          // always create
    Available_Only,    // stored only — no creation
}

Pool_Get_Result :: enum {
    Ok,             // item returned in m^
    Not_Available,  // Available_Only: nothing stored
    Not_Created,    // on_get returned nil
    Closed,         // pool is closed
    Already_In_Use, // m^ != nil on entry
}

pool_get :: proc(
    p: Pool,
    id: int,
    mode: Pool_Get_Mode,
    m: ^Maybe(^PolyNode),
) -> Pool_Get_Result

// Wait for stored item only.
// Does not call on_get.
pool_get_wait :: proc(
    p: Pool,
    id: int,
    m: ^Maybe(^PolyNode),
    timeout: time.Duration,
) -> Pool_Get_Result

// Return item to pool.
// Calls on_put.
pool_put :: proc(p: Pool, m: ^Maybe(^PolyNode))

// Return chain of items.
pool_put_all :: proc(p: Pool, m: ^Maybe(^PolyNode))
```

---

### Ownership rules

Get:

| Result | `m^` after |
| ------ | ---------- |
| `.Ok`  | non-nil    |
| other  | unchanged  |

Put:

| State       | Result         |
| ----------- | -------------- |
| open pool   | `m^ = nil`     |
| closed pool | `m^` unchanged |

---

### PoolHooks

```odin
PoolHooks :: struct {
    ctx:    rawptr,
    ids:    [dynamic]int,   // all > 0
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}
```

---

### Hook rules

on_get:

* `m^ == nil` → create new item
* `m^ != nil` → reinitialize

on_put:

* `m^ == nil` → already disposed
* `m^ != nil`:

  * keep → pool stores
  * dispose → set `m^ = nil`

---

## Infrastructure rules

* Infrastructure uses negative ids
* Infrastructure is not pooled by default
* Infrastructure must be closed before dispose

---

## Summary

* One handle → `Maybe(^PolyNode)`
* One movement → Mailbox
* One reuse → Pool
* One teardown → `matryoshka_dispose`

Everything follows the same rules.
