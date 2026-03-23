package hooks

import item "../item"

// Ctor_Dtor groups allocation and disposal callbacks.
// From years of C++ experience: ctor allocates, dtor frees.
//
// Both fields are required for useful operation.
// Note: PoolHooks (layer3+) adds ctx, in_pool_count params and merges
// create/reuse into on_get — not needed at doll1.
Ctor_Dtor :: struct {
	// ctor allocates the correct type for id, sets id, returns ^PolyNode.
	// Returns nil on failure or unknown id.
	ctor: proc(id: int) -> Maybe(^item.PolyNode),

	// dtor frees internal resources and the node itself, then sets m^ = nil.
	dtor: proc(m: ^Maybe(^item.PolyNode)),
}
