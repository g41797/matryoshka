/*
Package pool is a thread-safe free-list for reusable message objects.

Use it with mbox when you send many messages.

How it works:
- Call init to set up the pool and pre-allocate messages.
- Call get to take a message from the pool (or allocate a new one).
- Send the message via mbox.
- After receiving, call put to return the message to the pool.
- Call destroy when done. It frees all remaining pool messages.

The pool reuses the same "node" field that mbox requires.
A message is never in both the pool and a mailbox at the same time.

Your struct must have two fields required by the pool where clause:
  - "node" of type list.Node
  - "allocator" of type mem.Allocator  (set by pool.get on every retrieval)

	import list "core:container/intrusive/list"
	import "core:mem"

	My_Msg :: struct {
	    node:      list.Node,      // required by both pool and mbox
	    allocator: mem.Allocator,  // required by pool
	    data:      int,
	}

Status returns:
- init returns (bool, Pool_Status): (true, .Ok) on success; (false, .Out_Of_Memory) on pre-alloc failure.
- get returns (^T, Pool_Status): .Ok, .Pool_Empty, .Out_Of_Memory, or .Closed.
- put returns ^T: nil if the message was recycled or freed; the original pointer if it was foreign
  (msg.allocator != pool allocator — caller must free it).

Lifecycle:
- Pool_State.Uninit: zero value, init not yet called.
- Pool_State.Active: pool is running.
- Pool_State.Closed: destroyed or init failed.

Optional reset proc:
- Pass a proc(^T, Pool_Event) to init to register a cleanup/reinit hook.
- Called with .Get when a recycled message is returned from the free-list.
- Called with .Put before a message is returned to the free-list (or freed).
- NOT called for fresh allocations.
- Called outside the pool mutex.
*/
package pool
