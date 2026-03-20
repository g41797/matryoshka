# new-pool-design.md

## Overview

This document defines the redesigned ITC Pool.

The Pool is a **minimal, intrusive, MPMC-safe container for reusable intrusive nodes** (`^PolyNode`).

It does not implement policy, scheduling, or wakeup logic.

The Pool is strictly responsible for:
- storing reusable nodes
- providing nodes on demand
- accepting returned nodes
- final cleanup on close

All behavioral decisions are delegated to **FlowPolicy hooks**.

---

## Core Principles

### 1. Intrusive ownership model

The system operates on:

```

Maybe(^PolyNode)

````

Rules:
- `m != nil` → valid ownership transfer candidate
- `m == nil` → ownership consumed (disposed elsewhere)

---

### 2. Pool is MPMC

- Multiple producers may `put`
- Multiple consumers may `get`
- Pool must be thread-safe under concurrent access
- No ordering guarantees unless explicitly implemented

---

### 3. Pool is policy-agnostic

Pool MUST NOT:
- decide limits
- decide wakeups
- decide accept/reject logic
- interpret FlowId semantics

All such logic lives in FlowPolicy (`on_put`, etc.)

---

## FlowPolicy (SSOT for behavior)

```odin
FlowPolicy :: struct {
    ctx: rawptr,

    factory :: proc(
        ctx: rawptr,
        alloc: mem.Allocator,
    ) -> (^PolyNode, bool),

    on_put :: proc(
        ctx: rawptr,
        alloc: mem.Allocator,
        current_count: int,
        m: ^Maybe(^PolyNode),
    ),

    dispose :: proc(
        ctx: rawptr,
        alloc: mem.Allocator,
        m: ^Maybe(^PolyNode),
    ),
}
````

### Hook ownership rule

* Hooks MAY consume ownership:

  ```
  m = nil
  ```

* If `m != nil` after hook → Pool owns item again

* If `m == nil` → item is destroyed or transferred away

---

## Pool state model

The Pool maintains:

* Per-FlowId free lists of `^PolyNode`
* Internal synchronization primitives for MPMC safety

No additional metadata is required.

---

## API

### get

```odin
pool_get(id: int) -> ^PolyNode
```

Behavior:

1. Try pop from free list
2. If empty:

   * call `FlowPolicy.factory`
3. Return node

Guarantees:

* returned node is exclusively owned by caller

---

### put

```odin
pool_put(id: int, m: ^Maybe(^PolyNode))
```

Behavior:

1. Validate `m != nil`
2. Call policy hook:

```
on_put(ctx, alloc, current_count, &m)
```

3. Interpret result:

### Case A — consumed by hook

```
m == nil
```

→ Pool does nothing

### Case B — retained

```
m != nil
```

→ push into free list

---

### close

```odin
pool_close()
```

Behavior:

* iterate all free lists
* for each node:

  ```
  FlowPolicy.dispose(&m)
  ```
* free internal pool structures

Guarantee:

* no node survives pool lifetime

---

## Ownership rules

### 1. get → caller owns

```
Pool → Caller
```

### 2. put → ownership transfer into Pool or destruction

```
Caller → Pool OR Hook
```

### 3. hook may consume ownership

```
Hook → destruction OR external transfer
```

Pool must respect `m == nil`.

---

## Wakeuper (external concept)

Wakeuper is NOT part of Pool.

However, it may be triggered inside `on_put`.

Example usage:

```odin
on_put(...) {
    if current_count == 0 {
        wakeuper_notify()
    }
}
```

Rules:

* Pool MUST NOT call wakeuper
* Only application-level hook logic may do so

---

## Concurrency guarantees

Pool provides:

* MPMC-safe free list operations
* atomic or locked access (implementation-defined)
* no blocking guarantees required by spec

Pool does NOT provide:

* fairness
* scheduling
* priority handling

---

## Invariants

### I1 — ownership integrity

At all times:

```
m == nil OR m points to valid PolyNode
```

---

### I2 — no double ownership

A node is either:

* in pool
* owned by caller
* consumed by hook

Never multiple states.

---

### I3 — hook finality

After `on_put`:

```
m == nil → node is dead or transferred
m != nil → pool owns node
```

---

## Failure modes

### 1. Hook forgets to nullify after consuming

→ DOUBLE FREE RISK
→ MUST BE AVOIDED BY CONTRACT

---

### 2. Pool misinterprets m state

→ CORRUPTION
→ prevented by strict `Maybe` rule

---

### 3. Concurrent put/get races

→ handled by MPMC synchronization layer

---

## Design summary

* Pool = memory + reuse engine
* FlowPolicy = lifecycle logic engine
* Wakeuper = external application concern
* PolyNode = intrusive carrier of identity + links

---

## Final model

```
        FlowPolicy
            ↓
Caller → Pool → FreeList
   ↑        ↓
   └── get  ┘
```

Pool is a deterministic, policy-free allocator of reusable intrusive nodes.

```

---
