// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package item

import list "core:container/intrusive/list"
import "core:testing"

// PolyNode is the intrusive node embedded at offset 0 in every itc item.
//
// Embed via `using` at the first field:
//
//   Chunk :: struct {
//       using poly: PolyNode,  // offset 0 — required
//       data: [4096]byte,
//       len:  int,
//   }
//
// With `using`, field access is promoted: chunk.id == chunk.poly.id.
// The cast (^Chunk)(node) is valid only when PolyNode is at offset 0.
// itc has no compile-time check for this — enforced by convention.
//
// id rules:
//   - Must be != 0 after creation.
//   - Zero is always invalid (zero value of int — catches uninitialized nodes).
//   - Ids are user-defined, typically from an enum.
//
// Ownership is tracked via Maybe(^PolyNode) at every API boundary:
//
//   m: Maybe(^PolyNode)
//
//   m^ == nil   →  not yours (transferred, or nothing here)
//   m^ != nil   →  you own it — must transfer, recycle, or dispose
//   m  == nil   →  nil handle — invalid; API returns error
//
// Two levels of structural safety:
//   list.Node  — structural: one prev/next; a node cannot be in two queues at once.
//   Maybe      — contractual: nil/non-nil tells every API who holds the item.
PolyNode :: struct {
	using node: list.Node, // intrusive link — .prev, .next
	id:         int, // type discriminator, must be != 0
}

// --- Embedded tests ---

@(test)
test_poly_node_zero_value :: proc(t: ^testing.T) {
	n: PolyNode
	testing.expect(t, n.id == 0, "zero-value PolyNode must have id == 0")
	testing.expect(t, n.node.prev == nil, "zero-value node.prev must be nil")
	testing.expect(t, n.node.next == nil, "zero-value node.next must be nil")
}

@(test)
test_maybe_nil_semantics :: proc(t: ^testing.T) {
	m: Maybe(^PolyNode)
	testing.expect(t, m == nil, "zero-value Maybe must be nil")
	n: PolyNode
	m = &n
	testing.expect(t, m != nil, "Maybe set to non-nil pointer must not be nil")
	testing.expect(t, m.? == &n, "Maybe.? must return the stored pointer")
}

@(test)
test_offset_zero_cast :: proc(t: ^testing.T) {
	// Verify that embedding PolyNode at offset 0 makes (^PolyNode)(item) safe.
	Item :: struct {
		using poly: PolyNode, // offset 0
		value:      int,
	}
	item: Item
	item.id = 1
	item.value = 42
	// Cast to ^PolyNode — safe because PolyNode is at offset 0
	poly := (^PolyNode)(&item)
	testing.expect(t, poly.id == 1, "cast to ^PolyNode must preserve id")
	// Cast back — safe because id is known
	back := (^Item)(poly)
	testing.expect(t, back.value == 42, "cast back to ^Item must preserve value")
}

@(test)
test_id_zero_is_uninitialized :: proc(t: ^testing.T) {
	// id == 0 means the node was never stamped.
	// Callers must check id != 0 before use.
	n: PolyNode
	testing.expect(t, n.id == 0, "uninitialized PolyNode has id == 0 (invalid)")
	n.id = 1
	testing.expect(t, n.id != 0, "after stamping, id must be != 0")
}
