# odin-itc: The Architectural Model

This document explains the system structure, roles, and invariants of `odin-itc`. It is designed to be read by both architects and developers to understand the "why" and "how" of the system before diving into the API.

---

## 1. What odin-itc Is

**odin-itc** is a local message runtime for cooperating **Masters**. It provides a structured way for Masters to exchange data without direct calls, shared mutable state, or expensive memory allocations.

**Threads** (or any execution container) provide the CPU time to run these Masters, but they do not participate in the logic or own resources.

The system is built on five core concepts:
1. **Execution Containers:** Provide CPU time.
2. **Master:** The active agent that owns state and logic.
3. **Items:** The messages (intrusive objects).
4. **Mailboxes:** The transport (zero-copy queues).
5. **Pools:** The lifecycle managers.

---

## 2. The Core Components

### Execution Containers (Threads)
Containers are purely providers of execution time. They do not own runtime resources or perform logic. A container (like an OS thread or an event loop) repeatedly invokes a **Master**.
* **Role:** Receive a `^Master`, run its loop, and provide the stack/CPU.
* **Invariant:** Containers are "execution-only"; all active operations and state live in the Master.

### The Master (The Active Agent)
The Master is the central hub of a subsystem. It is a **heap-allocated** object because its lifetime must be independent of any single thread's stack.
* **Role:** Performs all system operations (`get`, `put`, `send`, `receive`). It owns pools and mailboxes, stores configuration, and contains the program logic.
* **Orchestration:** The Master decides when to create items, send messages, and shut down.

### Items (The Messages)
Items are **intrusive runtime objects**. Instead of being wrapped by a container, the metadata for the mailbox (the link node) is stored inside the item struct itself.
* **No Copies:** Messages move between threads by moving pointer ownership, never by copying data.
* **Standard Fields:** Every item typically includes a `list.Node` for mailboxes and a `mem.Allocator` for disposal.

### Mailboxes (The Transport)
A mailbox is a Multi-Producer, Single-Consumer (MPSC) intrusive queue.
* **Role:** It transports items but does not "own" them.
* **Properties:** Zero-copy, non-allocating transport that moves ownership from a sender to a receiver.

### Pools (The Lifecycle Manager)
Pools are more than just memory allocators; they are generic lifecycle managers for reusable objects (items, workers, or runtime components).
* **Flow:** `Factory (Create) → Reset (Prepare) → Use → Put (Recycle) → Dispose (Destroy)`.
* **Benefit:** Reduces pressure on the system allocator and ensures predictable object lifetimes.

---

## 3. The Ownership Rule

Safety in `odin-itc` is enforced through an explicit ownership protocol using the type:
`^Maybe(^T)` (A pointer to a maybe-pointer).

When you send an item:
1. You pass `&item_pointer`.
2. If the send **succeeds**, the pointer becomes `nil`. Ownership has moved.
3. If the send **fails**, the pointer remains valid. The caller retains ownership and must decide what to do (retry or dispose).

This pattern prevents the two most common concurrent bugs: **double-frees** and **lost messages**.

---

## 4. Runtime Diagram

This diagram illustrates how structure, ownership, and flow intersect in the runtime.

```text
                         EXECUTION CONTAINERS
                      (Threads / Loops / Schedulers)
                                │
                                │ repeatedly calls
                                ▼
                   ┌──────────────────────────┐
                   │          MASTER          │
                   │    (Heap-allocated state)│
                   │                          │
                   │  Owns:                   │
                   │  - Pools                 │
                   │  - Mailboxes             │
                   │  - Logic / Config        │
                   └──────┬────────────┬──────┘
                          │            │
                    Owns  │            │ Owns
                          ▼            ▼
               ┌──────────────┐    ┌──────────────┐
               │     POOL     │    │   MAILBOX    │
               │(Lifecycle)   │    │ (Transport)  │
               │              │    │              │
               │ Creates/Recycles  │ Moves Pointers
               └──────┬───────┘    └──────┬───────┘
                      │                   │
               Produces                   │ Transfers Ownership
                      ▼                   ▼
                    ITEMS (Intrusive Objects)
               ┌──────────────────────────────────┐
               │ node: list.Node                  │
               │ allocator: mem.Allocator         │
               │ user_payload...                  │
               └──────────────────────────────────┘
```

**The Item Flow:**
`Pool → Sender Master → Mailbox → Receiver Master → Pool`

---

## 5. Why This Structure?

The design of `odin-itc` prioritizes **predictable performance** and **simple reasoning**:

*   **Intrusive Design:** Eliminates "hidden" allocations when sending messages.
*   **Master Ownership:** Centralizes resource management, making shutdown and cleanup trivial (just destroy the Master).
*   **Orthogonality:** Each component does exactly one job. Pools manage time (lifecycle), mailboxes manage space (transport), and masters manage logic.

---

## 6. Core Invariants Summary

1.  **Items are intrusive:** Mailbox links are stored inside the data.
2.  **Ownership always moves:** Pointers are nil-ed out upon successful transfer.
3.  **Mailboxes transport, they don't own:** They are temporary conduits.
4.  **Pools manage lifecycles:** They are the ultimate source and sink for items.
5.  **Masters orchestrate:** Logic lives in the Master; Threads only provide CPU.
