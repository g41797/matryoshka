package examples_layer1

import "core:mem"

// Builder provides functions to construct and destruct
// PolyNode-based items with different types.
// Very naive - don't use in produnction
Builder :: struct {
	alloc: mem.Allocator,
}

// make_builder creates a Builder with the given allocator.
make_builder :: proc(alloc: mem.Allocator) -> Builder {
	return Builder{alloc = alloc}
}

// ctor allocates the correct type for id and sets id.
// Returns nil for unknown ids.
ctor :: proc(b: ^Builder, id: int) -> MayItem {
	switch ItemId(id) {
	case .Event:
		ev := new(Event, b.alloc)
		if ev == nil {
			return nil
		}
		ev.poly.id = id
		return MayItem(&ev.poly)
	case .Sensor:
		s := new(Sensor, b.alloc)
		if s == nil {
			return nil
		}
		s.poly.id = id
		return MayItem(&s.poly)
	case:
		return nil
	}
}

// dtor frees internal resources and the node, then sets m^ = nil.
// Safe to call with m == nil or m^ == nil (no-op).
dtor :: proc(b: ^Builder, m: ^MayItem) {
	if m == nil {
		return
	}
	ptr, ok := m.?
	if !ok {
		return
	}
	switch ItemId(ptr.id) {
	case .Event:
		free((^Event)(ptr), b.alloc)
	case .Sensor:
		free((^Sensor)(ptr), b.alloc)
	case:
		panic("unknown id")
	}
	m^ = nil
}
