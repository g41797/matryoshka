# Plan: Meta-Matryoshka — Infrastructure as PolyNodes

> Tracking the evolution of Mailbox and Pool into first-class PolyNode citizens.

## Author notes

Matryoshka does not force the user, except for two core requirements:
- Items must be based on `PolyNode` (offset 0).
- `Pool` requires `PoolHooks`.

The rest — including `Master`, `Builder`, and specific factory patterns — are **advice only**. Matryoshka doesn't care if your `Master` is a `PolyNode` or how you structure your `Builder`.

### ID Strategy: "Extreme Negatives"
Reserved system IDs should use extreme negative values to stay as far away as possible from user-defined IDs (which typically start at 1).
- `ID_MAILBOX = min(int)`
- `ID_POOL    = min(int) + 1`
- **Responsibility:** It is the user's responsibility not to overlap their IDs with these system ranges.

### Resource Management: "Self-Destroying" (Suicide)
- **Creator Stored:** Every infrastructure item (Mailbox, Pool) stores the `mem.Allocator` that was used to create it within its private structure.
- **Independence:** Once created, the item is self-contained. It can be sent, used, closed, and disposed of without the original factory.
- **Procedure:** `matryoshka.dispose(m: ^Maybe(^PolyNode))` is a standalone procedure.
  - It looks at `m^.id`.
  - It casts to the private internal struct (`_Mbox` or `_Pool`).
  - It checks if the item is **closed**.
  - **If Closed:** It uses the internal stored allocator to free the memory.
  - **If NOT Closed:** It returns an error/failure (you cannot dispose of a live item).

## The Matryoshka Object (Infrastructure Manager)

The `Matryoshka` object acts as a factory/manager for infrastructure. We offer two variants for creation:

### Variant A: The Factory Object (The Manager)
Best for grouping multiple infrastructure items under one allocator.
```odin
mtr := make_matryoshka(alloc)
m1  := get(mtr, ID_MBOX)
m2  := get(mtr, ID_POOL)
```

### Variant B: The Factory Functions (Surgical)
Best for single-item creation without overhead.
```odin
m := mbox_new(alloc)
p := pool_new(alloc)
```
*Both variants result in items that carry their own allocator and can be disposed of via `matryoshka.dispose(m)`.*

## Advanced Infrastructure Flow

### 1. Sending Infrastructure via Mailbox
- **Standard:** You can send a `Mailbox` or `Pool` through a `Mailbox`. 
- **Suicide Send (Self-Delegation):** A mailbox can be sent *to itself*.
  - `m: Maybe(^PolyNode) = (^PolyNode)(mb)`
  - `mbox_send(mb, &m)`
  - The sender loses ownership; the receiver gains ownership of the communication channel.

### 2. Pooling Infrastructure
- **Pool of Mailboxes:** Fully supported.
- **Recycling:** Internal `PoolHooks` for system types handle resetting internal state (clearing flags, draining queues) during `on_get`.
- **Use Case:** High-frequency session management.

## Objective
The goal is to unify the entire system under the `PolyNode` and `Maybe(^PolyNode)` ownership contract. Mailboxes and Pools should be "items" themselves, allowing for dynamic system reconfiguration and a single, unified lifecycle model.

## Refined Architecture: The Unified Lifecycle

### 1. Everything is a PolyNode
`Mailbox`, `Pool`, and future system items are `PolyNode` items.

```odin
// System ID Registry
SystemId :: enum int {
    Invalid = 0,
    Mailbox = min(int),
    Pool    = min(int) + 1,
}
```

### 2. Hiding via "Private Tail"
- **Public Handle:** `Mailbox :: distinct ^PolyNode`.
- **Private Struct:**
  ```odin
  _Mbox :: struct {
      using poly: PolyNode, // Header (Publicly visible id/node)
      alloc: mem.Allocator, // Private stored creator allocator
      _mutex: sync.Mutex,   // Private sync guts
      _cond:  sync.Cond,    // Private sync guts
      _list:  list.List,    // Private queue
      // ...
  }
  ```

## Verification & Testing
1.  **Test Case:** Create a `Mailbox`, send it through another `Mailbox`, receive it, and use it to send data.
2.  **Test Case:** Perform a "Suicide Send" (send mailbox to itself) and verify receiver gains ownership.
3.  **Test Case:** Verify that `matryoshka.dispose` correctly cleans up a **closed** `Mailbox` and fails for an **open** one.
