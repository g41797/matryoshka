# matryoshka vs. The Actor Model

This guide compares `matryoshka` with the classic Actor Model (Erlang, Akka).
Both use message passing, but they solve different problems.

---

## 1. The Core Philosophy

*   **Actors are "Biological":** They are independent cells. You can spawn millions. They die and regrow. They are dynamic.
*   **matryoshka is "Mechanical":** It is a high-speed engine. You build it once. It has a fixed number of cylinders (threads) and pipes (mailboxes). It is static.

---

## 2. Data Movement

### Actor Model: Copying (Safety First)
Most actor systems **copy** the data.
1.  Actor A sends a message to Actor B.
2.  The system makes a copy of the data.
3.  Both actors can work safely. No one can mess with the other's memory.
4.  **Cost:** Copying large data is slow.

### matryoshka: Ownership (Speed First)
We use **Zero-Copy Ownership**.
1.  Master A sends an **Item** to Master B.
2.  Master A passes the pointer and sets its own pointer to `nil`.
3.  Only Master B now owns the data. No one else can touch it.
4.  **Benefit:** Zero overhead. You can move 1GB as fast as 1 byte.

---

## 3. Addressing

*   **Actors use Addresses:** You send a message to "Actor #123". The system finds where that actor is (it might even be on a different computer).
*   **matryoshka uses Mailboxes:** You send an Item to a specific `Mailbox` pointer inside a Master. It is like a physical wire connecting two components on a circuit board.

---

## 4. Memory Management

*   **Actor Model:** Usually relies on a Garbage Collector (GC). The system cleans up messages when no one is using them.
*   **matryoshka:** Uses **Pools**. Every Item comes from a Pool and must return to a Pool. Memory is reused, not "collected." This makes performance very predictable.

---

## 5. Summary Table

| Feature | Actor Model | matryoshka |
| :--- | :--- | :--- |
| **Structure** | Dynamic (Spawn/Kill) | Static (Build once) |
| **Data** | Copying (Safe) | Ownership Move (Fast) |
| **Routing** | Address / ID | Mailbox Pointer |
| **Memory** | Garbage Collection | Pools / Recycling |
| **Scale** | Horizontal (Many machines) | Local (One machine, many threads) |

---

## 6. The Architect's Choice

### Use the Actor Model if:
*   You need to scale across a cluster of servers.
*   You have millions of small, simple entities (e.g., users in a game).
*   You want the system to automatically restart "dead" components.

### Use matryoshka if:
*   You are building a high-performance local engine (e.g., a media processor, a database, or a game engine).
*   You need to move large amounts of data between threads with zero lag.
*   You want complete control over memory and CPU usage.

**In short:** Actors are for **distributed systems**. `matryoshka` is for **high-speed local hardware utilization**.
