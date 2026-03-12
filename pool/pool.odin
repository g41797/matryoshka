// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package pool

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import "core:sync"
import "core:time"

// _PoolNode, _PoolMutex, _PoolAllocator, _PoolEvent, _PoolDuration ensure imports are used — required by -vet for generic code.
@(private)
_PoolNode :: list.Node
@(private)
_PoolMutex :: sync.Mutex
@(private)
_PoolAllocator :: mem.Allocator
@(private)
_PoolEvent :: Pool_Event
@(private)
_PoolDuration :: time.Duration

// Pool_State is the internal lifecycle of a pool.
Pool_State :: enum {
	Uninit, // zero value — init not yet called
	Active, // running
	Closed, // destroyed or init failed
}

// Pool_Status is returned by init and get.
Pool_Status :: enum {
	Ok, // success
	Pool_Empty, // free-list empty, strategy = .Pool_Only
	Out_Of_Memory, // allocator returned nil
	Closed, // pool is Closed or Uninit
}

// Pool_Event tells the reset proc why it was called.
Pool_Event :: enum {
	Get, // message is about to be returned to caller
	Put, // message is about to return to free-list (or be freed)
}

// Allocation_Strategy controls get() behavior when the pool is empty.
Allocation_Strategy :: enum {
	Pool_Only, // return nil if pool is empty
	Always, // allocate new if pool is empty (default)
}

// Pool is a thread-safe free-list for reusable message objects.
//
// Uses the same "node" field as mbox. A message is never in both at once.
// T must have a field named "node" of type list.Node and "allocator" of type mem.Allocator.
Pool :: struct($T: typeid) {
	allocator: mem.Allocator,
	mutex:     sync.Mutex,
	cond:      sync.Cond, // wakes waiting get(.Pool_Only) calls
	list:      list.List,
	curr_msgs: int,
	max_msgs:  int, // 0 = unlimited
	state:     Pool_State, // replaces closed: bool
	reset:     proc(msg: ^T, e: Pool_Event), // optional, called outside mutex
}

// init prepares the pool and pre-allocates initial_msgs messages.
// max_msgs sets a cap on the free-list size. 0 = unlimited.
// Returns (true, .Ok) on success; (false, .Out_Of_Memory) if any pre-allocation fails.
// On failure all already-allocated messages are freed and state is set to .Closed.
// Note: pre-allocated messages have msg.allocator unset; get sets it on retrieval.
init :: proc(
	p: ^Pool($T),
	initial_msgs := 0,
	max_msgs := 0,
	reset: proc(_: ^T, _: Pool_Event),
	allocator := context.allocator,
) -> (
	bool,
	Pool_Status,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") ==
	mem.Allocator {
	p.allocator = allocator
	p.max_msgs = max_msgs
	p.reset = reset

	for _ in 0 ..< initial_msgs {
		msg := new(T, allocator)
		if msg == nil {
			// Free all already-allocated messages and abort.
			for {
				raw := list.pop_front(&p.list)
				if raw == nil {
					break
				}
				m := container_of(raw, T, "node")
				free(m, allocator)
			}
			p.state = .Closed
			return false, .Out_Of_Memory
		}
		list.push_back(&p.list, &msg.node)
		p.curr_msgs += 1
	}

	p.state = .Active
	return true, .Ok
}

// get returns a message from the free-list.
// .Always (default): allocates a new one if the pool is empty. timeout is ignored.
// .Pool_Only + timeout==0: returns (nil, .Pool_Empty) immediately if empty (default behavior).
// .Pool_Only + timeout<0: waits forever until put or destroy.
// .Pool_Only + timeout>0: waits up to that duration; returns (nil, .Pool_Empty) on expiry.
// Returns (nil, .Closed) if the pool state is not Active (including destroy while waiting).
// Sets msg.allocator on every returned message. Calls reset(.Get) only for recycled messages.
get :: proc(
	p: ^Pool($T),
	strategy := Allocation_Strategy.Always,
	timeout: time.Duration = 0,
) -> (
	^T,
	Pool_Status,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") ==
	mem.Allocator {
	sync.mutex_lock(&p.mutex)

	if p.state != .Active {
		sync.mutex_unlock(&p.mutex)
		return nil, .Closed
	}

	raw := list.pop_front(&p.list)
	if raw == nil && strategy == .Pool_Only {
		if timeout == 0 {
			sync.mutex_unlock(&p.mutex)
			return nil, .Pool_Empty
		}
		// Wait loop: block until a message is available, pool is closed, or timeout expires.
		for p.list.head == nil {
			if p.state != .Active {
				sync.mutex_unlock(&p.mutex)
				return nil, .Closed
			}
			ok: bool
			if timeout < 0 {
				sync.cond_wait(&p.cond, &p.mutex)
				ok = true
			} else {
				ok = sync.cond_wait_with_timeout(&p.cond, &p.mutex, timeout)
			}
			if p.state != .Active {
				sync.mutex_unlock(&p.mutex)
				return nil, .Closed
			}
			if !ok {
				sync.mutex_unlock(&p.mutex)
				return nil, .Pool_Empty // timeout expired
			}
		}
		raw = list.pop_front(&p.list)
	}

	if raw != nil {
		p.curr_msgs -= 1
		alloc := p.allocator
		sync.mutex_unlock(&p.mutex)
		msg := container_of(raw, T, "node")
		msg.node = {}
		msg.allocator = alloc
		if p.reset != nil {
			// if message also used in another place, reset increase probablity of failure
			p.reset(msg, .Get)
		}
		return msg, .Ok
	}

	// strategy == .Always and pool was empty: fresh allocation — do not call reset.
	alloc := p.allocator
	sync.mutex_unlock(&p.mutex)

	msg := new(T, alloc)
	if msg == nil {
		return nil, .Out_Of_Memory
	}
	msg.allocator = alloc
	return msg, .Ok
}

// put returns msg to the free-list.
// Returns msg if it came from a different allocator (foreign — caller must free it).
// Returns nil if msg was recycled into the pool or freed by the pool.
// No-op if msg is nil (returns nil).
// Calls reset(.Put) before recycling, outside the mutex.
put :: proc(p: ^Pool($T), msg: ^T) -> ^T where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") == mem.Allocator {
	if msg == nil {
		return nil
	}

	// Foreign message: wrong allocator — return to caller.
	if msg.allocator != p.allocator {
		return msg
	}

	if p.reset != nil {
		p.reset(msg, .Put)
	}

	sync.mutex_lock(&p.mutex)

	if p.state != .Active || (p.max_msgs > 0 && p.curr_msgs >= p.max_msgs) {
		sync.mutex_unlock(&p.mutex)
		free(msg, msg.allocator)
		return nil
	}

	msg.node = {}
	list.push_back(&p.list, &msg.node)
	p.curr_msgs += 1
	sync.cond_signal(&p.cond) // wake one waiting get(.Pool_Only)
	sync.mutex_unlock(&p.mutex)
	return nil
}

// destroy frees all messages in the free-list and marks the pool Closed.
// After destroy: get returns (nil, .Closed), put frees own messages.
// Safe to call more than once.
// Call after all threads have stopped using the pool.
destroy :: proc(p: ^Pool($T)) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") == mem.Allocator {
	sync.mutex_lock(&p.mutex)

	if p.state == .Closed {
		sync.mutex_unlock(&p.mutex)
		return
	}
	p.state = .Closed

	// Use p.allocator because pre-allocated messages have msg.allocator unset.
	alloc := p.allocator
	for {
		raw := list.pop_front(&p.list)
		if raw == nil {
			break
		}
		msg := container_of(raw, T, "node")
		p.curr_msgs -= 1
		free(msg, alloc)
	}
	sync.cond_broadcast(&p.cond) // wake all waiting get(.Pool_Only) calls
	sync.mutex_unlock(&p.mutex)
}
