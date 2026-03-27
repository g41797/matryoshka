# Advice Catalog

Master checklist for all matryoshka advices.
Use this to track: creating tests, checking code, updating docs.

Tag rule: `[itc: tag]` only if it references matryoshka API. No tag for generic patterns.

---

## Generic (no itc tag)

| Tag | Name | One line |
|---|---|---|
| `explicit-alloc` | Explicit allocators | Pass allocator explicitly: `new(T, alloc)`, `free(ptr, alloc)`. Never rely on `context.allocator`. |
| `defer-cleanup` | Defer cleanup | Every allocated resource must be released on all paths. Use `defer`. |
| `defer-unlock` | Lock release safety | `defer sync.mutex_unlock(&m)` immediately after lock. |
| `errdefer` | Conditional defer | Named return + `defer if !ok { cleanup() }` for factory procs. |

## Layer 1 — PolyNode + Maybe + Builder

| Tag | Name | One line |
|---|---|---|
| `offset-zero` | PolyNode at offset 0 | Embed `using poly: PolyNode` as first field. Cast validity depends on it. |
| `id-nonzero` | Id must be != 0 | Use `enum int` starting at 1. Zero = uninitialized = bug. |
| `maybe-container` | Maybe as ownership bit | `m^ != nil` = you own it. `m^ == nil` = not yours. One variable, whole lifetime. |
| `two-value-unwrap` | Safe unwrap | Always `ptr, ok := m.?`. Never `ptr := m.?` (panics if nil). |
| `one-place` | One place at a time | Never insert same node in two lists. One `prev`, one `next`, one place. |
| `unknown-id-alloc` | Unknown id on alloc | `ctor`/`new` for unknown id → return `nil`. Same handling as allocation failure. |
| `unknown-id-free` | Unknown id on free | `dtor`/`free`/`drain` for unknown id → `panic`. Programming error, not runtime condition. |
| `builder-alloc` | Builder stores allocator | Builder struct holds allocator. All ctor/dtor use the stored one. |
| `defer-dtor` | Defer with dtor | `defer dtor(&b, &m)` — no-op if transferred (m^ == nil), cleans up if stuck. |
| `drain-list` | Drain intrusive list | Pop all, switch on id, free each. Panic on unknown id. |

## Layer 2 — Mailbox + Master

| Tag | Name | One line |
|---|---|---|
| `heap-master` | Heap-allocated master | `new(Master)` — threads hold `^Master`. Stack master = dangling pointers. |
| `thread-container` | Thread is a container | Thread proc casts `rawptr` to `^Master`, calls run. No ITC locals on stack. |
| `mbox-close-drain` | Drain after mbox_close | `mbox_close` returns remaining list. Walk it, matryoshka_dispose each node. Never discard. |
| `defer-dispose` | Defer mbox/pool dispose | `defer matryoshka_dispose(&m_mb)` right after new. Cleanup on all paths. |
| `send-transfer` | Send = ownership transfer | After `mbox_send` success, `m^ == nil`. Do not touch. Deferred cleanup becomes no-op. |

## Layer 3 — Pool + Hooks

| Tag | Name | One line |
|---|---|---|
| `defer-put` | Defer pool_put after get | `defer pool_put(&p, &m)` — safety net. No-op if already transferred. |
| `on-get-hygiene` | on_get sanitizes | `on_get` clears stale state for reuse. Never frees internal resources. |
| `on-put-backpressure` | on_put for limits | `on_put` checks `in_pool_count`. Dispose if over limit. `m^ = nil` → pool discards. |
| `pool-hooks` | PoolHooks pattern | Define hooks as `::` constant. Set `ctx` at runtime before `pool_init`. |
| `every-item-returned` | Every item must return | Three valid endings: `pool_put`, `mbox_send`, or dispose. No fourth option. |

---

## Status

| Advice | In advices.md? | Has test? | In docs? |
|---|---|---|---|
| `explicit-alloc` | yes | no | yes |
| `defer-cleanup` | yes | no | yes |
| `defer-unlock` | no | no | no |
| `errdefer` | no | no | no |
| `offset-zero` | no | no | yes (quickref) |
| `id-nonzero` | no | no | yes (quickref) |
| `maybe-container` | no | no | yes (quickref) |
| `two-value-unwrap` | no | no | yes (deepdive) |
| `one-place` | no | no | yes (deepdive) |
| `unknown-id-alloc` | yes | no | yes |
| `unknown-id-free` | yes | no | yes |
| `builder-alloc` | yes | no | yes |
| `defer-dtor` | no | no | yes (deepdive) |
| `drain-list` | yes | no | yes |
| `heap-master` | no | no | no |
| `thread-container` | no | no | no |
| `mbox-close-drain` | no | no | no |
| `defer-dispose` | no | no | no |
| `send-transfer` | no | no | no |
| `defer-put` | no | no | no |
| `on-get-hygiene` | no | no | no |
| `on-put-backpressure` | no | no | no |
| `pool-hooks` | no | no | no |
| `every-item-returned` | no | no | no |
