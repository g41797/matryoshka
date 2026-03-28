// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package matryoshka

import list "core:container/intrusive/list"

//////////////////////////////
MayItem :: Maybe(^PolyNode)
//////////////////////////////

// PolyNode is the intrusive node embedded at offset 0 in every matryoshka item.
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
// matryoshka has no compile-time check for this — enforced by convention.
//
// id rules:
//   - Must be != 0 after creation.
//   - Zero is always invalid (zero value of int — catches uninitialized nodes).
//   - Ids are user-defined, typically from an enum.
//
// Ownership is tracked via MayItem (alias for Maybe(^PolyNode)) at every API boundary:
//
//   m: MayItem
//
//   m^ == nil   →  not yours (transferred, or nothing here)
//   m^ != nil   →  you own it — must transfer, recycle, or dispose
//   m  == nil   →  nil handle — invalid; API returns error
//
// Two levels of structural safety:
//   list.Node  — structural: one prev/next; a node cannot be in two queues at once.
//   MayItem    — contractual: nil/non-nil tells every API who holds the item.
PolyNode :: struct {
	using node: list.Node, // intrusive link — .prev, .next
	id:         int, // type discriminator, must be != 0
}
