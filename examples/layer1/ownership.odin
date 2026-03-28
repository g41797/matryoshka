package examples_layer1

import list "core:container/intrusive/list"
import "core:mem"

// After push you no longer own the item.
// After pop you own it and must free or transfer it.
example_ownership :: proc(alloc: mem.Allocator) -> bool {
	l: list.List

	// 1. Allocate and stamp.
	ev := new(Event, alloc)
	if ev == nil {
		return false
	}
	ev.poly.id = int(ItemId.Event)
	ev.code = 99
	ev.message = "owned"

	// 2. Take ownership via MayItem.
	// [itc: typed-to-maybe] — MayItem is now the sole owner; do NOT defer free(ev).
	m: MayItem = &ev.poly

	// 3. Push to list — ownership transferred; set m to nil (you no longer own it).
	list.push_back(&l, &ev.poly.node)
	m = nil

	// 4. Pop — receive ownership.
	raw := list.pop_front(&l)
	if raw == nil {
		return false
	}
	out: MayItem = (^PolyNode)(raw)

	// 5. Verify, free, and clear the handle.
	ptr, ok := out.?
	if !ok {
		return false
	}
	owned_ev := (^Event)(ptr)
	if owned_ev.code != 99 {
		free(owned_ev, alloc)
		return false
	}
	free(owned_ev, alloc)
	out = nil

	return true
}
