package examples

import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:mem"

// Msg is the shared message type for all examples.
// "node" is required by mbox (and pool). The name is fixed. The type is list.Node.
// "allocator" is required by pool — set by pool.get on every retrieval.
Msg :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	data:      int,
}

// _msg_dispose is an internal helper for simple Msg cleanup that follows the contract.
// [itc: dispose-contract]
_msg_dispose :: proc(msg: ^Maybe(^Msg)) {
	if msg^ == nil { return }
	ptr := (msg^).?
	free(ptr, ptr.allocator)
	msg^ = nil
}

// DisposableMsg is a message with an internal heap-allocated field.
// It requires a dispose proc for final cleanup.
// It uses reset for reuse hygiene inside the pool.
DisposableMsg :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	data:      int,    // Common field for payload
	name:      string, // heap-allocated — must be freed before the struct
}

// disposable_reset clears stale state without freeing internal resources.
// Pool calls it automatically on get (before handing to caller) and on put (before free-list).
// Does NOT free name. Pool reuses the slot.
// [itc: reset-vs-dispose]
disposable_reset :: proc(msg: ^DisposableMsg, _: pool_pkg.Pool_Event) {
	msg.name = ""
	msg.data = 0
}

// disposable_dispose frees all internal resources, then frees the struct.
// Follows the ^Maybe(^T) contract: nil inner is a no-op. Sets inner to nil on return.
// Caller uses this for permanent cleanup. Pool and mailbox never call it.
// [itc: dispose-contract]
disposable_dispose :: proc(msg: ^Maybe(^DisposableMsg)) {
	if msg^ == nil {return}
	ptr := (msg^).?
	if ptr.name != "" {
		delete(ptr.name, ptr.allocator)
	}
	free(ptr, ptr.allocator)
	msg^ = nil
}
