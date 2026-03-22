# layers/LAYER.md — spiral layer state

> Resume anchor for layer implementation sessions.
> Start every session by reading this file.
> Update it after every  session.
> Spec source: `design/compose/design.md`

---

## Spiral spec

| Layer | What you have | What you don't need yet |
|-------|--------------|------------------------|
| 1 | `PolyNode` + `Maybe` | everything else |
| 2 | + hooks (`factory`, `dispose`) | pool, mailbox |
| 3 | + simple pool (wrapper around hooks) | extended pool, mailbox |
| 4 | + extended pool (free-list, flow control) | mailbox |
| 5 | + mailbox | — full itc |

**Rule:** move to the next layer because you need it — not because it is there.

---

## Layer status

| Layer | Status |
|-------|--------|
| 1 | complete |
| 2 | planned |
| 3 | not started |
| 4 | not started |
| 5 | not started |

---

## Layer 1 — complete

**Path:** `layers/layer1/`

**Note:** layer1 contains `hooks` (factory, on_get, on_put, dispose proc fields).
Per spec, hooks belong at layer2.
This is accepted — layer1 is a slightly richer layer1, all tests pass.

### Packages

| Package | Path | Import path (from inside layer1) | Contents |
|---------|------|----------------------------------|----------|
| item | `item/` | `"./item"` (local) | `PolyNode`, `Maybe` — foundation types |
| hooks | `hooks/` | `"../item"` (item is its dependency) | `FlowPolicy` struct — factory, on_get, on_put, dispose proc fields |
| examples/item | `examples/item/` | — | `Event`, `Sensor`, `ItemId`; `example_produce_consume`, `example_ownership` |
| examples/hooks | `examples/hooks/` | — | `item_factory`, `item_dispose`, `make_flow_policy` |
| tests/item | `tests/item/` | — | integration tests for examples/item |
| tests/hooks | `tests/hooks/` | — | 7 tests: factory_event, factory_sensor, factory_unknown, dispose, roundtrip, on_get/on_put nil, dispose_nil_handle |

### Key types

```odin
// package item
PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int,       // type discriminator, must be != 0
}

// package hooks
FlowPolicy :: struct {
    factory: proc(id: int) -> Maybe(^item.PolyNode),
    on_get:  proc(m: ^Maybe(^item.PolyNode)),
    on_put:  proc(m: ^Maybe(^item.PolyNode)),
    dispose: proc(m: ^Maybe(^item.PolyNode)),
}
```

Note: layer1 `FlowPolicy` proc signatures are simpler than the full spec.
The full spec (layer3+) adds `ctx rawptr`, `alloc mem.Allocator`, `in_pool_count int` params.

### Build

```sh
cd layers/layer1 && ./build_and_test.sh
```

Runs 5 opt levels (`none minimal size speed aggressive`) + doc smoke test.
All pass.

---

## Layer 2 — planned

**What it adds:** A lock-free MPSC queue operating on `^PolyNode` directly.
Sole change from `mpsc/queue.odin`: replace `Queue($T)` (generic, requires `node: list.Node`)
with a non-generic `Queue` working on `^PolyNode`.

**Source:** Vyukov algorithm from `mpsc/queue.odin` — same algorithm, same properties.

**Why layer 2:**
- Simpler than pool + mailbox (no blocking, no pool, no lifecycle hooks needed)
- Usable for simple MT producer-consumer systems on its own
- Builds on layer1's `PolyNode` — fits the spiral type contract
- Foundation for `loop_mbox` (a future layer)

### API

| Proc | Signature | Notes |
|------|-----------|-------|
| `init` | `proc(q: ^Queue)` | Initializes stub, head, tail, len |
| `push` | `proc(q: ^Queue, msg: ^Maybe(^item.PolyNode)) -> bool` | nil msg^ → no-op, returns false. On success: msg^ = nil, returns true |
| `pop` | `proc(q: ^Queue) -> ^item.PolyNode` | Returns nil on empty OR transient stall — caller retries |
| `length` | `proc(q: ^Queue) -> int` | Approximate count |

**pop return style:** returns `^PolyNode` directly (not out-param).
Rationale: nil means "empty or transient stall — retry", not an error.
Caller wraps for lifecycle tracking when needed: `m: Maybe(^PolyNode) = pop(&q)`.

**Queue is NOT copyable after init** — stub address is embedded in head/tail.

```odin
// package mpsc  (layers/layer2/mpsc/)
import item "../item"   // PolyNode from layer1

Queue :: struct {
    head: ^list.Node,
    tail: ^list.Node,
    stub: list.Node,
    len:  int,
}
```

### Directory layout

```
layers/layer2/
├── item/              — copy from layer1/item/ (PolyNode dependency, layer self-contained)
├── mpsc/              — PolyNode-adapted queue (~same size as mpsc/queue.odin)
├── examples/
│   └── mpsc/          — MT example: N producers, 1 consumer, dispatch on PolyNode.id
├── tests/
│   └── mpsc/          — unit tests + concurrency stress test
└── build_and_test.sh
```

### Examples scope

`examples/mpsc/` shows:
- Concrete types embedding `PolyNode` at offset 0
- Multiple producer goroutines pushing typed items
- Single consumer dispatching on `id` with `switch`
- Ownership transfer via `push` / wrap in `Maybe` after `pop`

### Tests scope

`tests/mpsc/`:
- Unit: init, empty pop, push/pop single, FIFO order, stall retry
- Stress: N producers × M items, consumer drains all, verify count and FIFO

### Build

```sh
cd layers/layer2 && ./build_and_test.sh
```

---

## Conventions

- Every layer lives under `layers/layerN/`.
- Each layer is a self-contained Odin workspace with its own `build_and_test.sh`.
- Packages import siblings via relative paths (e.g. `"../item"`).
- Update this file as part of every layer session — before ending the session.
