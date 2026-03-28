# Matryoshka — Hard Rules (Non-Negotiable)

This document defines rules that MUST be followed.

Violating any rule results in undefined behavior.

---

## 1. Intrusive Layout

- `PolyNode` MUST be the first field in every item.
- Casting between `^PolyNode` and concrete type relies on this.
- A `PolyNode` MUST NOT be part of more than one container at a time.
- A `PolyNode` MUST NOT be inserted twice into the same container.

---

## 2. Ownership (`Maybe(^PolyNode)`)

- `Maybe(^PolyNode)` represents UNIQUE ownership.
- If `m^ != nil` → you own the item.
- If `m^ == nil` → you do not own any item.

You MUST NOT:
- duplicate ownership
- alias the same pointer in multiple `Maybe`
- use an item after setting `m^ = nil`

You MUST:
- transfer ownership explicitly
- clear `m^` immediately after transfer

---

## 3. Ownership Transfer

Ownership changes ONLY via:

- `mbox_send`
- `mbox_wait_receive`
- pool `get` / `put`
- explicit destroy

### Send

- On `.Ok` → ownership moves to mailbox
- On error → sender retains ownership

### Receive

- On `.Ok` → receiver gains ownership
- Otherwise → ownership unchanged

---

## 4. Type Safety

- All casts from `^PolyNode` are unsafe.
- You MUST validate `id` before casting.

```odin
if ptr.id != ExpectedId {
    panic("invalid type")
}
````

* Using wrong type is undefined behavior.

---

## 5. Lifetime

An owned item MUST be:

* sent
* returned to pool
* or destroyed

Exactly once.

You MUST NOT:

* leak items
* double free
* use after free

---

## 6. Pool Rules

* `on_get` MUST return a valid, initialized item
* `on_put` MUST leave item in a valid state or destroy it

Semantics:

* Pool controls the flow — it decides when hooks are called (and when not to).
* When hooks are called, hooks decide the item's fate.
* `on_get`: hook creates or reinitializes — hook's call.
* `on_put`: hook keeps (`m^ != nil`) or destroys (`m^ = nil`) — hook's call.

You MUST NOT:

* assume item will be reused
* use item after passing to pool

---

## 7. Mailbox Rules

* Mailbox transfers ownership, not data
* Mailbox MAY be used from multiple threads (as documented)

You MUST NOT:

* access an item after sending it
* assume delivery if send fails

---

## 8. Infrastructure Objects

Mailbox and Pool:

* are owned objects
* are NOT regular data items

You MUST NOT:

* pool them
* treat them as reusable data
* ignore their lifecycle

---

## 9. Shutdown Rules

### Mailbox

Before disposing:

1. stop producers
2. stop consumers
3. drain or destroy remaining items
4. call `mbox_close`

Undefined behavior if items remain unhandled.

---

### Pool

Before disposing:

1. stop all users
2. ensure no items are in-flight

On dispose:

* all stored items MUST be destroyed

Undefined behavior if items are still in use.

---

## 10. Concurrency

* Ownership transfer is the ONLY synchronization mechanism
* User data MUST NOT be shared across threads

You MUST NOT:

* read or write data you do not own
* access item concurrently from multiple threads

---

## 11. Error Handling

On any failed operation:

* ownership remains with caller unless explicitly stated

You MUST:

* handle every error path
* resolve ownership explicitly

---

## 12. Invalid States

The following are ALWAYS bugs:

* two owners for one item
* item in multiple containers
* use after transfer
* use after free
* missing `id` validation
* disposing active mailbox or pool
* items escaping during shutdown

---

## 13. Mental Check

At every line involving an item, you must know:

* who owns it
* where it goes next
* who releases it

If not — the code is wrong.

```
