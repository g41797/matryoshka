# The odin-itc Mental Model

This guide explains how `odin-itc` works. It is for architects who need the big picture and developers who need to write the code.

---

## 1. The Core Idea

`odin-itc` is a system for **Masters** to talk to each other.

**Execution containers** (most commonly OS threads) provide CPU time to run Masters.
A container may run **one or several Masters**.

Masters do not call each other directly.
Instead, they exchange **Items** through **Mailboxes**.

All operations (`send`, `recv`, `get`, `put`) are performed by a Master.

The system is built on five pillars:

1. **Execution Containers:** provide CPU time.
2. **The Master:** the active logic and owner of runtime state.
3. **Items:** the objects being exchanged.
4. **Mailboxes:** the transport lanes.
5. **Pools:** the lifecycle managers.

---

## 2. The Players

### Execution Containers (The Engine)

Think of these as the engine. They provide CPU time.

Examples:

* OS threads
* event loops
* cooperative schedulers
* test harnesses

Properties:

* They **do not own runtime resources**.
* They contain **no application logic**.
* Their job is only to **drive Masters**.

A container may run one Master:

```
loop {
    master.run()
}
```

Or several Masters cooperatively:

```
loop {
    masterA.next()
    masterB.next()
}
```

The container only provides execution.

---

### The Master (The Active Logic)

The Master is the heart and "brain" of the system.

* It lives on the **heap**.
* It **owns runtime resources**.
* It **contains program logic**.

Typical Master contents:

```
Master {
    pools
    mailboxes
    configuration
}
```

The Master is responsible for:

* obtaining Items from Pools
* sending Items through Mailboxes
* receiving Items
* coordinating system behavior

Execution containers simply **call the Master's methods**.

---

### Items (The Messages)

Items are the objects moving through the system.

They are **intrusive runtime objects**.

Example:

```
Job {
    node: list.Node
    allocator: mem.Allocator
    job_id: u64
    payload: []u8
}
```

Important fields:

```
node       required by mailbox
allocator  used by pools and dispose
```

Because Items are intrusive:

* there are **no wrapper allocations**
* there are **no message copies**
* moving a message means **moving a pointer**

Items can represent:

* messages
* work units
* control signals
* reusable runtime objects

---

### Mailboxes (The Post Office)

Mailboxes move Items between Masters.

Properties:

* MPSC (Multi-Producer, Single-Consumer)
* intrusive queue
* zero-copy transport

Mailboxes do **not own Items**.

They only:

* store Items temporarily
* transfer ownership from sender to receiver
* wake receivers when needed

Mailboxes connect **Masters**, not Threads.

---

### Pools (The Warehouse)

Pools manage the **lifecycle of reusable objects**.

Pools can manage any type:

* message items
* worker structs
* runtime components
* user objects

The lifecycle is:

```
Create → Reset → Use → Recycle → Destroy
```

Meaning:

```
factory  creates object
reset    prepares it for reuse
put      returns object to pool
dispose  permanently destroys it
```

Pools control object lifetime and reduce allocation pressure.

---

## 3. The Ownership Rule

Safety in `odin-itc` is built on a single rule:

**Ownership must move.**

The system uses the type:

```
^Maybe(^T)
```

When sending an Item:

* you pass a pointer to your pointer

```
mbox.send(&m)
```

Results:

**If send succeeds**

```
m becomes nil
```

Ownership moved to the receiver.

**If send fails**

```
m remains valid
```

The sender still owns the object.

This rule prevents:

* double frees
* lost ownership
* dangling pointers

---

## 4. How Data Flows

```
       EXECUTION CONTAINER
           (thread, loop)

                │
                │ runs
                ▼

              MASTER
         (logic + state owner)

                │
         ┌──────┴──────┐
         ▼             ▼

       POOLS       MAILBOXES
    (Lifecycle)   (Transport)

         │             │
         └──────┬──────┘
                │
                ▼

              ITEMS
          (intrusive objects)
```

Typical flow:

1. Master gets Item from **Pool**.
2. Master sends Item through **Mailbox**.
3. Receiver Master processes Item.
4. Receiver returns Item to **Pool**.

---

## 5. The Golden Rules (Invariants)

The system relies on a small set of invariants:

1. **Items are intrusive.** Mailbox links live inside the item.
2. **Ownership moves.** Successful sends set the sender pointer to `nil`.
3. **Mailboxes transport but do not own.**
4. **Pools manage lifecycle.**
5. **Masters contain logic and state.**
6. **Execution containers only provide CPU time.**
7. **Pointers move, data does not.**

---

### Critical architectural truths

* Master-centric model
* thread as environment
* intrusive objects
* ownership transfer
* lifecycle pools
* message transport
* cooperative masters possible
