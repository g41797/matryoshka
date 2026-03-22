package examples

import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:mem"

// Itm is the shared item type for all examples.
// "node" is required by mbox (and pool). The name is fixed. The type is list.Node.
// "allocator" is required by pool — set by pool.get on every retrieval.
Itm :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	data:      int,
}

// _itm_dispose is an internal helper for simple Itm cleanup that follows the contract.
// [itc: dispose-contract]
_itm_dispose :: proc(itm: ^Maybe(^Itm)) {
	if itm == nil {return}
	if itm^ == nil {return}
	ptr := (itm^).?
	free(ptr, ptr.allocator)
	itm^ = nil
}

// DisposableItm is an item with an internal heap-allocated field.
// It requires a dispose proc for final cleanup.
// It uses reset for reuse hygiene inside the pool.
DisposableItm :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	data:      int, // Common field for payload
	name:      string, // heap-allocated — must be freed before the struct
}

// disposable_reset prepares the item for reuse without freeing internal resources.
// Pool calls it automatically on get (before handing to caller) and on put (before free-list).
// Does NOT free name. Pool reuses the slot.
// [itc: reset-vs-dispose]
disposable_reset :: proc(itm: ^DisposableItm, _: pool_pkg.Pool_Event) {
	itm.name = ""
	itm.data = 0
}

// disposable_dispose frees all internal resources, then frees the struct.
// Follows the ^Maybe(^T) contract: nil inner is a no-op. Sets inner to nil on return.
// Caller uses this for permanent cleanup. Pool calls it via T_Hooks.dispose.
// [itc: dispose-contract]
disposable_dispose :: proc(itm: ^Maybe(^DisposableItm)) {
	if itm == nil {return}
	if itm^ == nil {return}
	ptr := (itm^).?
	if ptr.name != "" {
		delete(ptr.name, ptr.allocator)
	}
	free(ptr, ptr.allocator)
	itm^ = nil
}

// disposable_factory allocates a DisposableItm and sets its allocator.
// Internal resources start at zero — valid for DisposableItm (name = "").
// On failure: returns (nil, false). Nothing to clean up for a zero-init struct.
disposable_factory :: proc(allocator: mem.Allocator) -> (^DisposableItm, bool) {
	itm := new(DisposableItm, allocator)
	if itm == nil {return nil, false}
	itm.allocator = allocator
	return itm, true
}

// DISPOSABLE_ITM_HOOKS is the compile-time hook table for DisposableItm.
// Pass it to pool_init for any pool that holds DisposableItm values.
DISPOSABLE_ITM_HOOKS :: pool_pkg.T_Hooks(DisposableItm) {
	factory = disposable_factory,
	reset   = disposable_reset,
	dispose = disposable_dispose,
}
