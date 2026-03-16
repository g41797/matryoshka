package examples

import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:mem"
import "core:strings"

// ForeignItm has a different allocator than the pool.
ForeignItm :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	name:      string,
}

foreign_dispose :: proc(itm: ^Maybe(^ForeignItm)) { // [itc: dispose-contract]
	if itm^ == nil { return }
	ptr := (itm^).?
	delete(ptr.name, ptr.allocator)
	free(ptr, ptr.allocator)
	itm^ = nil
}

// foreign_dispose_example demonstrates Idiom 6: foreign item with resources.
// It shows how pool.put detects an allocator mismatch and returns the pointer
// for manual disposal.
foreign_dispose_example :: proc() -> bool {
	p: pool_pkg.Pool(ForeignItm)
	pool_pkg.init(&p, initial_msgs = 0, max_msgs = 10, hooks = pool_pkg.T_Hooks(ForeignItm){})
	defer pool_pkg.destroy(&p) // [itc: defer-destroy]

	// Create an item with a DIFFERENT allocator (e.g., a custom tracking allocator or just a different context).
	// For this test, we'll just use a fresh allocator instance if possible, or simulate by changing the field.

	itm := new(ForeignItm)
	itm.allocator = context.temp_allocator // Different from p.allocator (context.allocator)
	itm.name = strings.clone("i am foreign", itm.allocator)

	itm_opt: Maybe(^ForeignItm) = itm // [itc: maybe-container]

	// Try to put it into the pool.
	ptr, accepted := pool_pkg.put(&p, &itm_opt)

	// [itc: foreign-dispose]
	if !accepted && ptr != nil {
		// The pool rejected it because of allocator mismatch.
		// We MUST dispose it manually using its own allocator.
		p_opt: Maybe(^ForeignItm) = ptr
		foreign_dispose(&p_opt)
		return true
	}

	return false
}
