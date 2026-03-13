// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package mpsc

import "base:intrinsics"
import list "core:container/intrusive/list"

// _ListNode keeps -vet happy — it does not count generic field types as import usage.
@(private)
_ListNode :: list.Node

// Queue is a lock-free multi-producer, single-consumer queue.
// T must have a field named "node" of type list.Node.
//
// Queue is NOT copyable after init — stub is an embedded sentinel node;
// head and tail store its address on init. Copying after init breaks the queue.
Queue :: struct($T: typeid) {
	head: ^list.Node, // producer end — updated atomically by multiple producers
	tail: ^list.Node, // consumer end — updated by single consumer only
	stub: list.Node,  // sentinel node; address used by head and tail
	len:  int,        // item count — updated atomically
}

// init sets up the queue. Call once before push or pop.
init :: proc(q: ^Queue($T)) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	q.stub.next = nil
	q.head = &q.stub
	q.tail = &q.stub
	q.len = 0
}

// push adds msg to the queue. Safe to call from multiple threads at the same time.
push :: proc(q: ^Queue($T), msg: ^T) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	node := &msg.node
	intrinsics.atomic_store(&node.next, nil)
	prev := intrinsics.atomic_exchange(&q.head, node)
	// Stall window: between the exchange above and the store below,
	// consumer may see prev.next == nil and return nil from pop.
	// Consumer must treat nil as "try again". The next pop will succeed.
	intrinsics.atomic_store(&prev.next, node)
	intrinsics.atomic_add(&q.len, 1)
}

// pop removes and returns one message. Call from a single consumer thread only.
//
// Returns nil in two cases:
//   - Queue is empty.
//   - Stall: a producer has started push but not yet finished linking the node.
//     In a stall, len may be > 0 while pop returns nil.
//     Treat nil as "try again". The next call to pop will return the message.
pop :: proc(q: ^Queue($T)) -> ^T where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	tail := q.tail
	next := intrinsics.atomic_load(&tail.next)
	if tail == &q.stub {
		if next == nil {
			return nil // empty
		}
		q.tail = next
		tail = next
		next = intrinsics.atomic_load(&tail.next)
	}
	if next != nil {
		q.tail = next
		intrinsics.atomic_sub(&q.len, 1)
		return container_of(tail, T, "node")
	}
	// One item may remain or a stall is in progress.
	// Check whether head still points at tail.
	head := intrinsics.atomic_load(&q.head)
	if tail != head {
		return nil // stall — producer exchanged head but has not set next yet
	}
	// Single item remaining. Recycle the stub sentinel.
	q.stub.next = nil
	prev := intrinsics.atomic_exchange(&q.head, &q.stub)
	intrinsics.atomic_store(&prev.next, &q.stub)
	next = intrinsics.atomic_load(&tail.next)
	if next != nil {
		q.tail = next
		intrinsics.atomic_sub(&q.len, 1)
		return container_of(tail, T, "node")
	}
	return nil // stall after recycling
}

// length returns the approximate number of items in the queue.
// May be > 0 while pop returns nil (stall state — see pop comment).
length :: proc(q: ^Queue($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	return intrinsics.atomic_load(&q.len)
}
