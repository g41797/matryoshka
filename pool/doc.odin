/*
Package pool is a thread-safe free-list for reusable item objects.

Use it with mbox when you send many items.

How it works:
- Call init to set up the pool and pre-allocate items.
- Call get to take an item from the pool (or allocate a new one).
- Send the item via mbox.
- After receiving, call put to return the item to the pool.
- Call destroy when done. It frees all remaining pool items.

The pool reuses the same "node" field that mbox requires.
An item is never in both the pool and a mailbox at the same time.

Your struct must have two fields:
  - "node" of type list.Node
  - "allocator" of type mem.Allocator  (set by pool.get on every retrieval)

	import list "core:container/intrusive/list"
	import "core:mem"

	My_Itm :: struct {
	    node:      list.Node,      // required by both pool and mbox
	    allocator: mem.Allocator,  // required by pool
	    data:      int,
	}

Idiom reference: design/idioms.md

Status returns:
- init returns (bool, Pool_Status): (true, .Ok) on success; (false, .Out_Of_Memory) on pre-allocation failure.
- get returns (^T, Pool_Status): .Ok, .Pool_Empty, .Out_Of_Memory, or .Closed.
  With .Pool_Only strategy and timeout parameter:
  - timeout==0 (default): return immediately if empty (.Pool_Empty). Non-blocking.
  - timeout<0: wait forever until put or destroy.
  - timeout>0: wait up to that duration; returns (nil, .Pool_Empty) on expiry.
  - Returns (nil, .Closed) if pool is destroyed while waiting.
- put returns ^T: nil if recycled or freed. Returns the original pointer if the item is foreign (itm.allocator != pool allocator) — caller must free or dispose it.

Lifecycle:
- Pool_State.Uninit: zero value, init not yet called.
- Pool_State.Active: pool is running.
- Pool_State.Closed: destroyed or init failed.

T_Hooks — optional hooks for item lifecycle:
- Pass T_Hooks(T) by value to init. Zero value T_Hooks(T){} = all defaults (new/no-op/free).
- All three fields are optional independently. nil field = default behavior.
- T_Hooks holds type-level hooks only. The allocator is a separate init parameter.
- Define hooks once as a :: compile-time constant next to the item type.
- Odin cannot infer T from {} alone — always write T_Hooks(MyItm){} or a named constant.
- factory: called for every fresh allocation (pre-alloc in init, .Always path in get).
  - nil: new(T, allocator) is used. get sets itm.allocator.
  - not nil: must allocate the struct, initialize internal resources, set itm.allocator.
  - On failure: must clean up everything itself, return (nil, false).
  - The pool passes its allocator to factory on every call.
- reset: called with .Get when a recycled item is returned from the free-list.
  - Called with .Put before an item is returned to the free-list (or permanently freed).
  - nil: no reset.
  - NOT called for fresh allocations.
  - Called outside the pool mutex.
- dispose: called instead of free when permanently destroying an item.
  - Sites: destroy loop, put when pool is full or closed, destroy_itm.
  - nil: free(itm, allocator) is used.
  - not nil: must free all internal resources, free the struct itself, set itm^ = nil.
*/
package pool

/*
Note: Some test procedures may appear in the generated documentation.
This is because they are part of the same package to allow for white-box testing.
*/
