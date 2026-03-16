// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package pool

import wakeup "../wakeup"
import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import "core:sync"
import "core:time"

// _PoolNode, _PoolMutex, _PoolAllocator, _PoolEvent, _PoolDuration, _PoolWaker keep -vet happy — it does not count generic field types as import usage.
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
@(private)
_PoolWaker :: wakeup.WakeUper

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
	Get, // item is about to be returned to caller
	Put, // item is about to return to free-list (or be freed)
}

// Allocation_Strategy controls get() behavior when the pool is empty.
Allocation_Strategy :: enum {
	Pool_Only, // return nil if pool is empty
	Always, // allocate new if pool is empty (default)
}

// T_Hooks holds optional hooks for item lifecycle.
// factory: called for every fresh allocation. nil = new(T, allocator).
// reset:   called on get (recycled) and put (before free-list or freed). nil = no-op.
// dispose: called when permanently destroying an item. nil = free(itm, allocator).
// Zero value {} = all defaults. Pass by value to init.
T_Hooks :: struct($T: typeid) {
	factory: proc(allocator: mem.Allocator) -> (^T, bool),
	reset:   proc(itm: ^T, e: Pool_Event),
	dispose: proc(itm: ^Maybe(^T)),
}

// Pool is a thread-safe free-list for reusable item objects.
//
// Uses the same "node" field as mbox. An item is never in both at once.
// T must have a field named "node" of type list.Node and "allocator" of type mem.Allocator.
Pool :: struct($T: typeid) {
	allocator:          mem.Allocator,
	mutex:              sync.Mutex,
	cond:               sync.Cond, // wakes waiting get(.Pool_Only) calls
	list:               list.List,
	curr_msgs:          int,
	max_msgs:           int, // 0 = unlimited
	state:              Pool_State, // lifecycle state
	hooks:              T_Hooks(T), // optional hooks; zero value = all nil = defaults
	waker:              wakeup.WakeUper, // optional — notify non-blocking callers; pass {} for none
	empty_was_returned: bool, // true when get(.Pool_Only,0) found empty; cleared on next put
}

// init prepares the pool and pre-allocates initial_msgs items.
// max_msgs sets a cap on the free-list size. 0 = unlimited.
// hooks: zero value {} = all defaults (new/no-op/free). Pass by value. See T_Hooks.
// allocator: the allocator used for all new/free calls. Default = context.allocator.
// Returns (true, .Ok) on success; (false, .Out_Of_Memory) if any pre-allocation fails.
// On failure all already-allocated items are freed and state is set to .Closed.
// Note: when factory is nil, pre-allocated items have itm.allocator unset; get sets it on retrieval.
// Note: when factory is not nil, it must set itm.allocator itself.
init :: proc(
	p: ^Pool($T),
	initial_msgs := 0,
	max_msgs := 0,
	hooks: T_Hooks(T), // zero value {} = all default behaviors
	waker: wakeup.WakeUper = {},
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
	if p.state == .Active {
		return false, .Closed
	}
	p.hooks = hooks
	p.allocator = allocator
	p.max_msgs = max_msgs
	p.waker = waker

	for _ in 0 ..< initial_msgs {
		itm: ^T
		if p.hooks.factory != nil {
			ok: bool
			itm, ok = p.hooks.factory(allocator)
			if !ok {
				// factory cleans up after itself on failure; free already-allocated items.
				_destroy_list(p, allocator)
				p.state = .Closed
				return false, .Out_Of_Memory
			}
		} else {
			itm = new(T, allocator)
			if itm == nil {
				_destroy_list(p, allocator)
				p.state = .Closed
				return false, .Out_Of_Memory
			}
		}
		list.push_back(&p.list, &itm.node)
		p.curr_msgs += 1
	}

	p.state = .Active
	return true, .Ok
}

// _destroy_list frees all items in p.list using dispose or free.
@(private)
_destroy_list :: proc(p: ^Pool($T), allocator: mem.Allocator) {
	for {
		raw := list.pop_front(&p.list)
		if raw == nil {
			break
		}
		m := container_of(raw, T, "node")
		p.curr_msgs -= 1
		if p.hooks.dispose != nil {
			m_opt: Maybe(^T) = m
			p.hooks.dispose(&m_opt)
		} else {
			free(m, allocator)
		}
	}
}

// get returns an item from the free-list.
// .Always (default): allocates a new one if the pool is empty. timeout is ignored.
// .Pool_Only + timeout==0: returns (nil, .Pool_Empty) immediately if empty (default behavior).
// .Pool_Only + timeout<0: waits forever until put or destroy.
// .Pool_Only + timeout>0: waits up to that duration; returns (nil, .Pool_Empty) on expiry.
// Returns (nil, .Closed) if the pool state is not Active (including destroy while waiting).
// Sets itm.allocator on every returned item (when factory is nil). Calls reset(.Get) only for recycled items.
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
			p.empty_was_returned = true
			sync.mutex_unlock(&p.mutex)
			return nil, .Pool_Empty
		}
		// Block until an item is available, the pool is closed, or timeout expires.
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
		itm := container_of(raw, T, "node")
		itm.node = {}
		itm.allocator = alloc
		if p.hooks.reset != nil {
			// reset clears the item and exposes stale-pointer bugs early.
			p.hooks.reset(itm, .Get)
		}
		return itm, .Ok
	}

	// strategy == .Always and pool was empty: fresh allocation — do not call reset.
	alloc := p.allocator
	sync.mutex_unlock(&p.mutex)

	if p.hooks.factory != nil {
		itm, ok := p.hooks.factory(alloc)
		if !ok {
			return nil, .Out_Of_Memory
		}
		return itm, .Ok
	}

	itm := new(T, alloc)
	if itm == nil {
		return nil, .Out_Of_Memory
	}
	itm.allocator = alloc
	return itm, .Ok
}

// put returns itm to the free-list.
// nil inner (itm^ == nil) → (nil, true) no-op.
// own item: itm^ = nil, returned to free-list or freed → (nil, true).
// foreign item (allocator differs): itm^ = nil, returns (ptr, false) — caller must free or dispose ptr.
// Calls reset(.Put) before recycling, outside the mutex.
put :: proc(
	p: ^Pool($T),
	itm: ^Maybe(^T),
) -> (
	^T,
	bool,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") ==
	mem.Allocator {
	if itm^ == nil {
		return nil, true // nil inner — no-op
	}
	ptr := (itm^).?

	// Foreign item: wrong allocator — nil caller's var, return ptr.
	if ptr.allocator != p.allocator {
		itm^ = nil
		return ptr, false
	}

	if p.hooks.reset != nil {
		p.hooks.reset(ptr, .Put)
	}

	sync.mutex_lock(&p.mutex)

	if p.state != .Active || (p.max_msgs > 0 && p.curr_msgs >= p.max_msgs) {
		sync.mutex_unlock(&p.mutex)
		if p.hooks.dispose != nil {
			p.hooks.dispose(itm)
		} else {
			free(ptr, ptr.allocator)
			itm^ = nil
		}
		return nil, true
	}

	pool_was_empty := p.list.head == nil // capture before push (Zig-aligned: only wake on empty→non-empty)
	ptr.node = {}
	list.push_back(&p.list, &ptr.node)
	p.curr_msgs += 1
	sync.cond_signal(&p.cond) // wake one waiting get(.Pool_Only)
	was_flag := p.empty_was_returned
	p.empty_was_returned = false // always clear
	waker := p.waker
	sync.mutex_unlock(&p.mutex)
	// Call wake outside mutex to avoid deadlock if wake acquires a lock.
	if pool_was_empty && was_flag && waker.wake != nil {
		waker.wake(waker.ctx)
	}
	itm^ = nil
	return nil, true
}

// destroy_itm frees itm^ using the pool's allocator (or dispose hook) and sets itm^ = nil.
// No-op if itm^ is nil. Use when send fails and the unsent item must be freed.
destroy_itm :: proc(p: ^Pool($T), itm: ^Maybe(^T)) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") == mem.Allocator {
	if itm^ == nil {
		return
	}
	if p.hooks.dispose != nil {
		p.hooks.dispose(itm)
	} else {
		ptr := (itm^).?
		free(ptr, p.allocator)
		itm^ = nil
	}
}

// destroy frees all items in the free-list and marks the pool Closed.
// After destroy: get returns (nil, .Closed), put frees own items.
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

	// Use p.allocator because pre-allocated items (factory == nil) have itm.allocator unset.
	alloc := p.allocator
	_destroy_list(p, alloc)
	sync.cond_broadcast(&p.cond) // wake all waiting get(.Pool_Only) calls
	waker := p.waker
	sync.mutex_unlock(&p.mutex)
	// Free waker resources. Do not call wake — callers polling with get(.Pool_Only,0) will get .Closed on next call.
	if waker.close != nil {
		waker.close(waker.ctx)
	}
}

// length returns the number of items currently in the free-list.
// Thread-safe. Reads curr_msgs under mutex.
length :: proc(p: ^Pool($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node,
	intrinsics.type_has_field(T, "allocator"),
	intrinsics.type_field_type(T, "allocator") == mem.Allocator {
	sync.mutex_lock(&p.mutex)
	n := p.curr_msgs
	sync.mutex_unlock(&p.mutex)
	return n
}
