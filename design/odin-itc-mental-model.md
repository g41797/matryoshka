# The odin-itc Mental Model

This guide explains how `odin-itc` works. It is for architects who need the big picture and developers who need to write the code.

---

## 1. The Core Idea

`odin-itc` is a system for **Masters** to talk to each other. 
**Threads** are just containers that provide CPU time to run a Master.

Masters do not call each other directly. 
Instead, they exchange **Items** through **Mailboxes**. 
All operations (`send`, `recv`, `get`, `put`) are performed by a Master.

The system is built on five pillars:
1.  **Execution Containers (Threads):** They provide the CPU time.
2.  **The Master:** The active logic and owner of the state.
3.  **Items:** The actual messages.
4.  **Mailboxes:** The transport lanes.
5.  **Pools:** The lifecycle managers.

---

## 2. The Players

### Execution Containers (The Engine)
Think of these as the engine. They provide power (CPU time). 
*   They can be OS threads, event loops, or schedulers.
*   They do not own any resources and have no logic of their own. 
*   They only exist to "drive" the **Master**.

### The Master (The Active Logic)
The Master is the heart and "brain" of the system. 
*   It lives on the **heap**. This is important. 
*   The Master **calls the functions**: it gets items from pools, sends them to mailboxes, and receives them back.
*   The Master owns the logic, the pools, and the mailboxes.

### Items (The Messages)
Items are the data being moved. They are **intrusive**.
*   This means the "link" to the next item is stored *inside* the message struct itself.
*   There are no extra wrappers or "box" allocations.
*   Moving a message is just moving a pointer. **Zero copies.**

### Mailboxes (The Post Office)
Mailboxes move Items from one Master to another.
*   They are "MPSC" (Multi-Producer, Single-Consumer).
*   They do not "own" the Items. They just hold them briefly.
*   They move ownership from the sender to the receiver.

### Pools (The Warehouse)
Pools manage the life and death of objects.
*   They create, reset, recycle, and destroy Items or worker structs.
*   They stop the system from constantly asking the OS for memory.
*   **The Lifecycle:** Create → Reset → Use → Recycle → Destroy.

---

## 3. The Ownership Rule

Safety in `odin-itc` is built on a single rule: **Ownership must move.**

We use the type `^Maybe(^T)`.
*   When you send an item, you pass a pointer to your pointer.
*   **If send succeeds:** Your pointer becomes `nil`. The receiver now owns it.
*   **If send fails:** Your pointer stays valid. You still own it. You must decide what to do.

This prevents "double-frees" and lost messages.

---

## 4. How Data Flows

```text
       EXECUTION CONTAINER (Thread)
                │
                │ runs
                ▼
              MASTER (The Owner)
                │
         ┌──────┴──────┐
         ▼             ▼
       POOLS       MAILBOXES
    (Lifecycle)   (Transport)
         │             │
         └──────┬──────┘
                │
                ▼
              ITEMS (Intrusive)
```

**The Loop:** 
1. Get Item from **Pool**.
2. Send Item through **Mailbox**.
3. Receiver processes Item.
4. Receiver puts Item back in **Pool**.

---

## 5. The Golden Rules (Invariants)

To keep the system stable, these rules never change:

1.  **Items are Intrusive:** Mailbox links are part of the message data.
2.  **Ownership moves:** Successful sends always set the sender's pointer to `nil`.
3.  **Mailboxes are conduits:** They transport pointers but do not own them.
4.  **Pools are the sink and source:** Every item starts and ends at a Pool.
5.  **Masters are the state:** Containers run logic, but the Master *owns* the logic.
6.  **Zero-copy:** We move pointers, not data.
