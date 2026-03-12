// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package pool

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import "core:sync"

// _PoolNode, _PoolMutex, _PoolAllocator ensure imports are used — required by -vet for generic code.
@(private)
_PoolNode :: list.Node
@(private)
_PoolMutex :: sync.Mutex
@(private)
_PoolAllocator :: mem.Allocator

// Allocation_Strategy controls get() behavior when the pool is empty.
Allocation_Strategy :: enum {
	Pool_Only, // return nil if pool is empty
	Always,    // allocate new if pool is empty (default)
}

// Pool is a thread-safe free-list for reusable message objects.
//
// Uses the same "node" field as mbox. A message is never in both at once.
// T must have a field named "node" of type list.Node.
Pool :: struct($T: typeid) {
	allocator: mem.Allocator,
	mutex:     sync.Mutex,
	list:      list.List,
	curr_msgs: int,
	max_msgs:  int, // 0 = unlimited
	closed:    bool,
}

// init prepares the pool and pre-allocates initial_msgs messages.
// max_msgs sets a cap on the free-list size. 0 = unlimited.
// Returns false if any pre-allocation fails.
init :: proc(
	p: ^Pool($T),
	initial_msgs := 0,
	max_msgs := 0,
	allocator := context.allocator,
) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	p.allocator = allocator
	p.max_msgs = max_msgs

	for _ in 0 ..< initial_msgs {
		msg := new(T, allocator)
		if msg == nil {
			return false
		}
		list.push_back(&p.list, &msg.node)
		p.curr_msgs += 1
	}

	return true
}

// get returns a message from the free-list.
// .Always (default): allocates a new one if the pool is empty.
// .Pool_Only: returns nil if the pool is empty.
// Returns nil if the pool is closed.
get :: proc(
	p: ^Pool($T),
	strategy := Allocation_Strategy.Always,
) -> ^T where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)

	if p.closed {
		return nil
	}

	raw := list.pop_front(&p.list)
	if raw != nil {
		p.curr_msgs -= 1
		msg := container_of(raw, T, "node")
		msg.node = {}
		return msg
	}

	if strategy == .Pool_Only {
		return nil
	}

	return new(T, p.allocator)
}

// put returns msg to the free-list.
// Frees msg if the pool is full (max_msgs reached) or closed.
// No-op if msg is nil.
put :: proc(
	p: ^Pool($T),
	msg: ^T,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if msg == nil {
		return
	}

	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)

	if p.closed || (p.max_msgs > 0 && p.curr_msgs >= p.max_msgs) {
		free(msg, p.allocator)
		return
	}

	msg.node = {}
	list.push_back(&p.list, &msg.node)
	p.curr_msgs += 1
}

// destroy frees all messages in the free-list and marks the pool closed.
// After destroy: get returns nil, put frees the message.
// Call after all threads have stopped using the pool.
destroy :: proc(
	p: ^Pool($T),
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)

	if p.closed {
		return
	}
	p.closed = true

	for {
		raw := list.pop_front(&p.list)
		if raw == nil {
			break
		}
		msg := container_of(raw, T, "node")
		free(msg, p.allocator)
		p.curr_msgs -= 1
	}
}
