package hooks

import item "../item"

// Ctor_Dtor groups allocation and disposal callbacks.
// From years of C++ experience: ctor allocates, dtor frees.
// on_get and on_put are extensions for pool reuse — not required here.
//
// All four fields are optional (nil is valid — no-op for that callback).
// ctor and dtor are required for useful operation; on_get and on_put
// are left nil when not needed.
Ctor_Dtor :: struct {
	// ctor allocates the correct type for id, sets id, returns ^PolyNode.
	// Returns nil on failure or unknown id.
	ctor:    proc(id: int) -> Maybe(^item.PolyNode),

	// on_get is called before a recycled item is returned to the caller.
	// Use it to prepare the item for reuse. Must NOT free resources.
	on_get:  proc(m: ^Maybe(^item.PolyNode)),

	// on_put is called during pool_put, outside the lock.
	// Set m^ = nil to consume the item; otherwise the pool recycles it.
	on_put:  proc(m: ^Maybe(^item.PolyNode)),

	// dtor frees internal resources and the node itself, then sets m^ = nil.
	dtor:    proc(m: ^Maybe(^item.PolyNode)),
}
