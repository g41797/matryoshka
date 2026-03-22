# Ownership and Lifecycle Idioms

These idioms focus on the safe transfer of ownership and the management of an object's lifecycle, especially when dealing with pooled, disposable items.

---

## Ownership Model

| Tag | Name | One line |
|-----|------|----------|
| `maybe-container` | Maybe as container | Wrap a heap pointer in `Maybe(^T)` before any pointer-transferring call. |
| `dispose-contract` | dispose signature contract | A dispose proc takes `^Maybe(^T)`. Nil inner is a no-op. Sets inner to nil on return. |
| `defer-dispose` | defer with dispose | Use `defer dispose(&m)` so cleanup runs in all paths. |
| `errdefer-dispose`| conditional defer for factory procs | Use named return + `defer if !ok { dispose(...) }` when a factory proc creates and returns a master. |
| `dispose-optional`| dispose is advice | dispose is called by the caller, never by pool or mailbox. |

### `maybe-container` — Maybe as container
**Problem**: You have a `^T` from `new` or `pool_get`. You want to pass it to `send` or `push` safely.
**Fix**: Wrap it in `Maybe(^T)` before any pointer-transferring call.
```odin
// [itc: maybe-container]
m: Maybe(^Itm) = new(Itm)
mbox_send(&mb, &m)
// m is nil here — transfer complete, mailbox holds the pointer
```

### `dispose-contract` — dispose signature contract
**Problem**: A struct contains internal heap resources. You need a proc to free them all safely.
**Fix**: Write a dispose proc that follows the `^Maybe(^T)` contract. It takes `^Maybe(^T)`, is a no-op if the inner pointer is `nil`, and sets the inner pointer to `nil` on return.

### `defer-dispose` — defer with dispose
**Problem**: You fill an item with internal heap resources before sending. If `send` fails, you need to clean up.
**Fix**: Register `dispose` via `defer` right after wrapping in `Maybe`.
```odin
m: Maybe(^DisposableItm) = itm
defer disposable_dispose(&m)  // [itc: defer-dispose]
// ...
if mbox_send(&mb, &m) { /* success */ }
// If send fails, `m` is not nil, and the deferred dispose runs.
// If send succeeds, `m` is nil, and the deferred dispose is a no-op.
```

---

## Object Lifecycle / Pool Model

| Tag | Name | One line |
|-----|------|----------|
| `defer-put` | defer with pool.put | Use `defer pool.put` to return to pool in all paths. |
| `disposable-itm` | DisposableItm full lifecycle | Items with internal heap resources use a full, careful lifecycle. |
| `foreign-dispose` | foreign item with resources | When put returns a foreign pointer, call dispose, not free. |
| `reset-vs-dispose` | reset vs dispose | `reset` clears state for reuse. `dispose` frees internal resources permanently. |
| `t-hooks` | T_Hooks pattern | Define factory/reset/dispose as a `::` constant next to the type. |


### `defer-put` — defer with pool.put
**Problem**: You `get` an item from the pool and must return it in all paths.
**Fix**: Use `defer pool.put` immediately after acquisition. If the item is successfully transferred elsewhere (e.g., via `mbox_send`), its `Maybe` container becomes `nil` and the `put` becomes a no-op.

### `reset-vs-dispose` — reset vs dispose
**Problem**: It is easy to confuse `reset` (for reuse) with `dispose` (for permanent cleanup).
**Fix**: Keep them separate. Never free internal resources in `reset`.
- **`reset`**: Prepares item for reuse. Called by the pool before returning an item to the free list.
- **`dispose`**: Frees internal resources permanently. Called by the pool on permanent destruction.

### `t-hooks` — T_Hooks pattern
**Problem**: A complex item type needs custom logic for allocation, reset, and disposal.
**Fix**: Define `factory`, `reset`, and `dispose` procedures and register them in a `pool.T_Hooks` constant. Pass this constant to `pool_init`. The pool will then call your custom procedures at the appropriate lifecycle points.
