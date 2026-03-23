# Idioms Overview

This section provides a quick reference for matryoshka idioms. Each idiom has a short tag for `grep`.

These are not laws. No one is forced to follow them. They are patterns that have worked. Take what helps, ignore the rest.

---

## The Golden Rule: One Variable Lifecycle

**Mantra:** One convention across all transfer points. Same variable, whole lifetime, misuse detected at every boundary.

### The Rule

1.  **`^Maybe(^T)` replaces `^T` return:** Wherever an item is acquired or transferred (`get`, `receive`), it is passed as a parameter, not returned.
2.  **Check on Entry:** Every proc checks `itm^ != nil` on entry. If the caller still holds an item, it returns `.Already_In_Use`. This prevents overwriting valid data.
3.  **One Variable:** The caller uses a single variable from `get` -> `send` -> `wait_receive` -> `put` -> `dispose`.

### Lifecycle in one variable

```odin
m: Maybe(^Itm)

// 1. Acquire
get(&p, &m)            // Returns .Already_In_Use if m != nil
defer dispose(&m)      // Safety net: no-op if transferred, cleans up if stuck

// 2. Use
// fill m^ ...

// 3. Transfer
send(&mb, &m)          // m = nil on success (dispose becomes no-op)
                       // m != nil on failure (dispose cleans up)

// 4. Loop
// On next iteration, get(&p, &m) verifies m is nil.
```

---

## Building Blocks

matryoshka has five object types. Every concurrent system built with this library uses them. Understanding what each one is—and why it exists—makes the idioms easier to follow.

- **Master:** The actor. It has the logic. You define this as a pattern.
- **Thread:** A container. It runs one Master proc and nothing else.
- **Item (`Itm`):** Any reusable object managed by a pool.
- **Pool:** Holds a set of reusable items.
- **Mbox (Mailbox):** Moves a pointer from one Master to another.

---

## Marker Scheme

Each idiom has a short tag. The tag appears as a comment at the relevant line in code:

```odin
// [itc: <tag>]
```

To find all usages of one idiom:
`grep -r "\[itc: maybe-container\]" examples/ tests/`

---

## Quick Reference

| Tag | Name | One line |
|-----|------|----------|
| `maybe-container` | Maybe as container | Wrap a heap pointer in `Maybe(^T)` before any pointer-transferring call. |
| `defer-put` | defer with pool.put | Use `defer pool.put` to return to pool in all paths. |
| `dispose-contract` | dispose signature contract | A dispose proc takes `^Maybe(^T)`. Nil inner is a no-op. Sets inner to nil on return. |
| `defer-dispose` | defer with dispose | Use `defer dispose(&m)` so cleanup runs in all paths. |
| `disposable-itm` | DisposableItm full lifecycle | Items with internal heap resources use a full, careful lifecycle. |
| `foreign-dispose` | foreign item with resources | When put returns a foreign pointer, call dispose, not free. |
| `reset-vs-dispose` | reset vs dispose | `reset` clears state for reuse. `dispose` frees internal resources permanently. |
| `dispose-optional` | dispose is advice | `dispose` is called by the caller, never by pool or mailbox. |
| `heap-master` | ITC participants in a heap-allocated struct | Heap-allocate the struct that owns ITC participants. |
| `thread-container` | thread is just a container for its master | A thread proc only casts rawptr to `^Owner`. |
| `errdefer-dispose` | conditional defer for factory procs | Use named return + `defer if !ok { dispose(...) }` in factory procs. |
| `defer-destroy` | destroy resources at scope exit | Register `defer destroy` for resources to guarantee shutdown. |
| `t-hooks` | T_Hooks pattern | Define factory/reset/dispose as a `::` constant next to the type. |

This overview provides a high-level look. See the specific pages for **Ownership and Lifecycle** and **Concurrency Structure** for detailed explanations of each idiom.
