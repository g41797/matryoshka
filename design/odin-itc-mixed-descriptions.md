# odin-itc: How the pieces fit

This document explains the system in plain terms.
No API details. Only the model.

Read this before the other documents.

Related docs:

* `design/idioms.md` — coding rules
* `design/micro_system.md` — example scenario

---

# 1 What odin-itc is

odin-itc is a **local message system for threads**.

Threads do not call each other.
Threads exchange **items** through **mailboxes**.

Memory reuse is handled by **pools**.

The system is small. Only a few concepts:

```
Master
Thread
Item
Mailbox
Pool
```

Everything else follows from these.

---

# 2 The basic structure

A running program usually looks like this:

```
threads
   │
   ▼
Master (heap object)
   │
   ├─ pools
   └─ mailboxes
```

Rules:

* The **Master owns everything**.
* Threads only hold `^Master`.
* Threads do not own resources.

This keeps lifetime simple.

---

# 3 Master

A **Master** is the central struct of a subsystem.

It usually contains:

```
Master {
    pools
    mailboxes
    configuration
}
```

The Master decides:

* when to create items
* when to send messages
* when to receive messages
* when to shut down

The Master is **heap allocated**.

Reason:

```
threads store ^Master
```

If Master lived on a stack frame, threads could keep invalid pointers.

---

# 4 Threads

Threads are only containers.

Example:

```
worker :: proc(data: rawptr) {

    m := (^Master)(data)

    master_run(m)
}
```

Thread responsibilities:

* receive `^Master`
* call the run procedure

Threads should **not declare pools or mailboxes**.

All state lives in the Master.

---

# 5 Items

An **item** is a message object.

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
allocator  used by pool / dispose
```

Items are **intrusive**.

This means:

* mailbox links are stored inside the item
* no wrapper allocation
* no message copy

Messages move between threads by **moving ownership of the pointer**.

---

# 6 Mailboxes

A mailbox transports items between threads.

Conceptually:

```
sender thread
     │
     ▼
   mailbox
     │
     ▼
receiver thread
```

Properties:

* queue of intrusive items
* multi-producer
* single-consumer
* zero-copy

The mailbox **does not allocate items**.

It only moves pointers.

---

# 7 Pools

Pools manage reusable items.

Example lifecycle:

```
factory → reset → use → put → reset → use → ...
```

Steps:

1. pool creates item
2. item is used as message
3. item returns to pool
4. item is reset
5. reused again

Final destruction:

```
dispose
```

Pools reduce allocations and control object lifetime.

---

# 8 Ownership rule

The system uses a simple ownership protocol.

```
^Maybe(^T)
```

Meaning:

```
Maybe(^T)
```

holds a pointer that might be nil.

When sending an item:

```
mbox.send(&m)
```

If send succeeds:

```
m becomes nil
```

Ownership moved to the receiver.

If send fails:

```
m still contains the pointer
```

Caller decides what to do.

This prevents:

* double free
* lost messages

---

# 9 Item lifecycle example

Typical send flow:

```
itm, _ := pool.get(&p)

m: Maybe(^Job) = itm

mbox.send(&outbox, &m)
```

Receiver:

```
msg, _ := mbox.receive(&inbox)

pool.put(&p, &msg)
```

The item travels:

```
pool → sender → mailbox → receiver → pool
```

---

# 10 Shutdown

Shutdown usually follows this order:

```
close mailboxes
drain remaining items
return items to pools
destroy pools
join threads
destroy master
```

Important rule:

```
all items must return to pools
```

before pools are destroyed.

---

# 11 Why the system is structured this way

The design goals were:

```
no message copies
simple ownership
predictable lifetime
orthogonal components
```

Components are independent:

```
pool     manages memory
mailbox  transports items
thread   executes logic
master   owns resources
```

Each part has one job.

---

# 12 What the other documents do

This file explains **the model**.

Other documents explain details.

### idioms.md

Coding patterns:

```
maybe-container
defer-dispose
defer-put
heap-master
thread-container
```

These are practical rules for using the model safely.

---

### micro_system.md

Example conversation.

Two developers design a simple system:

```
spool server
worker server
```

The dialog shows how real protocols lead naturally to:

* items
* mailboxes
* pools

---

# 13 Short summary

odin-itc is built on a few simple ideas:

```
items are intrusive objects
mailboxes move ownership
pools reuse memory
masters own resources
threads are containers
```

Everything in the system follows these rules.

* **pool is generic lifecycle manager**, not just memory reuse
* **master orchestrates the system through messaging**
* **items are intrusive runtime objects**


## Short architectural summary

odin-itc is a small runtime for message-based thread cooperation.

The system is built from a few simple components.

---

## Master

A **Master** is a heap object that owns the runtime state of a subsystem.

Typical contents:

* pools
* mailboxes
* configuration

The Master **orchestrates work** by sending and receiving items through mailboxes.

Threads receive `^Master` and operate on it.

---

## Threads

Threads are execution containers.

They do not own runtime resources.

A thread usually:

* receives `^Master`
* runs a loop
* interacts with pools and mailboxes

All state lives in the Master.

---

## Items

An **item** is a message object.

Items are **intrusive runtime objects**.

Typical fields:

```
node: list.Node
allocator: mem.Allocator
```

The mailbox links items using the intrusive node.

Items are **never copied**.

---

## Mailboxes

A mailbox transports items between threads.

Properties:

* intrusive queue
* multi-producer
* single-consumer
* zero-copy transport

The mailbox does not allocate or destroy items.

It only moves ownership.

---

## Pools

A pool manages the **lifecycle of reusable objects**.

Objects may be:

* message items
* worker structs
* runtime components
* any user-defined type

A pool can create, reset, recycle, and destroy objects.

Typical lifecycle:

```
factory → reset → use → put → reset → reuse → … → dispose
```

Pools are not limited to memory reuse.
They provide controlled lifecycle management.

---

## Ownership

Ownership is transferred explicitly using:

```
^Maybe(^T)
```

When an item is sent:

```
mbox.send(&m)
```

If the send succeeds, the pointer inside `m` becomes `nil`.

Ownership moved to the receiver.

This prevents double-free and lost ownership.

---

## System picture

A typical subsystem looks like this:

```
threads
   │
   ▼
Master
   │
   ├─ pools
   └─ mailboxes
```

Items travel through the system:

```
pool → sender → mailbox → receiver → pool
```

The Master coordinates the flow.

---

## Core rules

The system relies on a few invariants:

```
items are intrusive objects
ownership always moves
mailboxes transport but do not own
pools manage object lifecycle
threads do not own runtime state
```

Everything else in odin-itc follows these rules.

Architectural note:

This document now includes **all required invariants**:

1. intrusive items
2. ownership transfer
3. mailbox transport role
4. pool lifecycle role
5. master orchestration role

That is the **minimum complete explanation**.

Anything shorter will lose important meaning.

---

For odin-itc the important things are:

- who owns
- who moves items
- who creates / destroys
- where threads sit

Everything else is detail.

This diagram shows the runtime in one picture.

A good architectural diagram must show **structure and flow**, not components only.

For odin-itc the important things are:

* who **owns**
* who **moves items**
* who **creates / destroys**
* where **threads sit**

Everything else is detail.

This diagram shows the runtime in one picture.

## odin-itc runtime diagram

```
                         THREADS
                (execution containers only)

        ┌──────────────┐        ┌──────────────┐
        │   worker A   │        │   worker B   │
        │              │        │              │
        │  recv/send   │        │  recv/send   │
        └──────┬───────┘        └──────┬───────┘
               │                       │
               │                       │
               ▼                       ▼


                   ┌──────────────────────┐
                   │        MASTER        │
                   │  (heap-owned state)  │
                   │                      │
                   │  pools               │
                   │  mailboxes           │
                   │  configuration       │
                   └───────┬───────┬──────┘
                           │       │
                           │       │
                 owns      │       │ owns
                           │       │


               ┌───────────▼───┐   ┌───────────────┐
               │     POOL      │   │    MAILBOX    │
               │ lifecycle mgr │   │ transport     │
               │               │   │               │
               │ factory       │   │ intrusive     │
               │ reset         │   │ MPSC queue    │
               │ recycle       │   │               │
               │ dispose       │   │ moves items   │
               └───────┬───────┘   └───────┬───────┘
                       │                   │
                       │ creates           │ transfers
                       │                   │ ownership
                       ▼                   ▼


                      ITEMS (intrusive objects)

                     ┌────────────────────┐
                     │  node: list.Node   │
                     │  allocator         │
                     │  user fields...    │
                     └────────────────────┘


item flow:

    pool → sender → mailbox → receiver → pool


ownership rule:

    ^Maybe(^Item)
```

Core properties:

* items are **intrusive objects**
* mailbox **moves ownership**
* pool **controls lifecycle**
* master **owns and orchestrates**
* threads **execute but do not own**

Why this diagram works (architecturally):

It shows **four different relations** clearly:

```
threads → execute
master → owns
pool → creates
mailbox → transports
```

Most diagrams fail because they mix these.

---

# odin-itc runtime model

This document explains how the system is structured.

It describes the **roles of the main components** and how they interact.

This is not an API description.
It explains the **programming model**.

Related documents:

* `design/idioms.md` — coding patterns and safety rules
* `design/micro_system.md` — example system

---

# 1 What odin-itc is

odin-itc is a **local message runtime for cooperating components**.

Components exchange **items** through **mailboxes**.
Object lifetime is managed by **pools**.

The system is intentionally small.

Core elements:

```
execution container
master
pool
mailbox
item
```

Everything else follows from these.

---

# 2 Execution containers

An **execution container** provides CPU time.

Typical containers:

```
thread
event loop
test harness
cooperative scheduler
```

The container repeatedly **invokes masters**.

Example:

```
loop {
    master.run()
}
```

A container may run **one master** or **many masters**.

Example cooperative loop:

```
loop {
    masterA.next()
    masterB.next()
    masterC.next()
}
```

`next()` is used only when a container schedules **multiple masters cooperatively**.

Most systems run a single master and call:

```
master.run()
```

Important rule:

```
execution containers do not own runtime resources
```

They only drive execution.

---

# 3 Masters

A **Master** is the central runtime component.

The master:

* contains **program logic**
* owns **runtime resources**
* coordinates work through messaging

Typical contents:

```
Master {
    pools
    mailboxes
    configuration
}
```

Masters are **heap objects**.

Reason:

```
execution containers store ^Master
```

The master is the **active element** of the system.
Execution containers only provide the environment.

---

# 4 Master execution

Masters normally expose a `run` method.

Example:

```
master.run()
```

The execution container repeatedly calls this method.

Example:

```
proc thread_main(data: rawptr) {

    m := (^Master)(data)

    m.run()
}
```

Some containers may drive masters step-by-step using:

```
master.next()
```

This is useful when multiple masters share one container.

Typical cooperative scheduling:

```
loop {
    masterA.next()
    masterB.next()
}
```

This is optional and not required for normal operation.

---

# 5 Items

An **item** is a message object.

Items are **intrusive runtime objects**.

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

The mailbox links items through the intrusive node.

Items are **never copied**.

Threads exchange items by **moving ownership of pointers**.

---

# 6 Mailboxes

A mailbox transports items between masters.

Conceptually:

```
sender master
      │
      ▼
    mailbox
      │
      ▼
receiver master
```

Properties:

```
intrusive queue
multi-producer
single-consumer
zero-copy transport
```

The mailbox **does not create or destroy items**.

Its job is only:

```
store items
transfer ownership
wake receivers
```

---

# 7 Pools

Pools manage the **lifecycle of reusable objects**.

Pools are generic and can manage any type.

Examples:

```
message items
worker structs
runtime components
user objects
```

Typical lifecycle:

```
factory → reset → use → put → reset → reuse → … → dispose
```

Meaning:

```
factory   creates object
reset     prepares object for reuse
put       returns object to pool
dispose   permanently destroys object
```

Pools are not limited to memory reuse.
They control **object lifecycle**.

---

# 8 Ownership model

odin-itc uses explicit ownership transfer.

The protocol uses:

```
^Maybe(^T)
```

Example:

```
m: Maybe(^Job)
```

When sending:

```
mbox.send(&m)
```

If the send succeeds:

```
m becomes nil
```

Ownership moved to the receiver.

If the send fails:

```
m still holds the pointer
```

The caller decides what to do.

This prevents:

```
double free
lost ownership
```

---

# 9 Item flow

A typical item travels like this:

```
pool → master → mailbox → master → pool
```

Example:

```
itm, _ := pool.get(&p)

m: Maybe(^Job) = itm

mbox.send(&outbox, &m)
```

Receiver:

```
msg, _ := mbox.receive(&inbox)

pool.put(&p, &msg)
```

Items circulate through the system.

---

# 10 System picture

```
execution container
        │
        │ runs
        ▼
      MASTER
        │
        │ owns
        ▼
 ┌───────────────┐
 │ pools         │
 │ mailboxes     │
 └───────┬───────┘
         │
         ▼
       ITEMS
```

Item movement:

```
pool → master → mailbox → master → pool
```

---

# 11 Core rules

The system relies on a small set of invariants.

```
items are intrusive objects
ownership always moves
mailboxes transport but do not own
pools manage object lifecycle
masters contain logic and resources
execution containers only provide execution
```

Everything in odin-itc follows these rules.
