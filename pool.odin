// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package matryoshka

import list "core:container/intrusive/list"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:time"

////////////////////
Pool :: ^PolyNode
////////////////////

@(private)
_Pool :: struct {
	using poly: PolyNode,
	alctr:      mem.Allocator,
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	hooks:      ^PoolHooks,
	lists:      map[int]list.List, // Free-lists per item ID.
	counts:     map[int]int,       // Number of idle items per item ID.
	closed:     bool,
}

// pool_new creates a new Pool instance.
pool_new :: proc(alloc: mem.Allocator) -> Pool {
	p, err := new(_Pool, alloc)
	if err != .None {
		return nil
	}

	p^.alctr = alloc
	p^.id = POOL_ID
	p^.lists = make(map[int]list.List, 16, alloc)
	p^.counts = make(map[int]int, 16, alloc)

	return cast(Pool)p
}

// pool_init registers the hooks for the pool.
// Panics if the pool handle is invalid.
pool_init :: proc(p: Pool, hooks: ^PoolHooks) {
	ptr := _unwrap_pool(p)
	if ptr.id != POOL_ID {
		panic("non-pool handle used for pool_init")
	}

	if hooks == nil {
		panic("pool_init: hooks cannot be nil")
	}

	if len(hooks.ids) == 0 {
		panic("pool_init: hooks.ids cannot be empty")
	}

	for id in hooks.ids {
		if id <= 0 {
			panic("pool_init: all ids must be positive")
		}
	}

	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)

	if ptr.closed {
		panic("pool_init: pool is already closed")
	}

	ptr.hooks = hooks
}

// pool_close marks the pool as closed and returns all stored items.
// Further get/put operations will fail or behave as no-ops.
pool_close :: proc(p: Pool) -> (list.List, ^PoolHooks) {
	ptr := _unwrap_pool(p)
	if ptr.id != POOL_ID {
		panic("non-pool handle used for pool_close")
	}

	all_items := list.List{}
	hooks: ^PoolHooks

	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)

	if ptr.closed {
		return all_items, nil
	}

	ptr.closed = true
	hooks = ptr.hooks
	ptr.hooks = nil

	// Consolidate all items from all free-lists into one list.
	for id in ptr.lists {
		if list_ptr, ok := ptr.lists[id]; ok {
			for {
				node := list.pop_front(&list_ptr)
				if node == nil { break }
				list.push_back(&all_items, node)
			}
		}
	}

	// The maps are freed by matryoshka_dispose.

	sync.cond_broadcast(&ptr.cond)

	return all_items, hooks
}

// pool_get acquires an item from the pool.
pool_get :: proc(p: Pool, id: int, mode: Pool_Get_Mode, m: ^MayItem) -> Pool_Get_Result {
	ptr := _unwrap_pool(p)
	if ptr.id != POOL_ID {
		panic("non-pool handle used for pool_get")
	}

	if id == 0 {
		panic("pool_get: id cannot be 0")
	}

	if m == nil {
		return .Not_Created
	}

	if m^ != nil {
		return .Already_In_Use
	}

	switch mode {
	case .Available_Or_New:
		return _pool_get_available_or_new(ptr, id, m)
	case .New_Only:
		return _pool_get_new_only(ptr, id, m)
	case .Available_Only:
		return _pool_get_available_only(ptr, id, m)
	}

	return .Not_Available
}

// pool_get_wait blocks until an item is available in the pool.
// Never calls on_get.
pool_get_wait :: proc(p: Pool, id: int, m: ^MayItem, timeout: time.Duration) -> Pool_Get_Result {
	ptr := _unwrap_pool(p)
	if ptr.id != POOL_ID {
		panic("non-pool handle used for pool_get_wait")
	}

	if id == 0 {
		panic("pool_get_wait: id cannot be 0")
	}

	if m == nil {
		return .Not_Available
	}

	if m^ != nil {
		return .Already_In_Use
	}

	return _pool_get_wait_impl(ptr, id, m, timeout)
}

// pool_put returns an item to the pool.
pool_put :: proc(p: Pool, m: ^MayItem) {
	if m == nil || m^ == nil {
		return
	}

	ptr := _unwrap_pool(p)
	if ptr.id != POOL_ID {
		panic("non-pool handle used for pool_put")
	}

	node, _ := m^.?
	if node.id == 0 {
		panic("pool_put: id cannot be 0")
	}

	_pool_put_impl(ptr, node, node.id, m)
}

// pool_put_all returns a chain of items to the pool.
//
// Phase 1 validates all ids in the chain before any put — ensures no partial state
// on bad input. Phase 2 resets each node (clears stale prev/next from the chain linkage)
// and puts it into the pool.
pool_put_all :: proc(p: Pool, m: ^MayItem) {
	if m == nil || m^ == nil {
		return
	}

	first, _ := m^.?

	ptr := _unwrap_pool(p)
	if ptr.id != POOL_ID {
		panic("non-pool handle used for pool_put_all")
	}

	_pool_put_all_validate(ptr, first)
	_pool_put_all_exec(p, first, m)
}

// _pool_check_ready validates inside-lock preconditions common to all get/wait operations.
// Must be called with ptr.mutex held.
// Returns .Closed if the pool is closed; panics on uninitialized pool or foreign id.
@(private)
_pool_check_ready :: proc(ptr: ^_Pool, id: int) -> Pool_Get_Result {
	if ptr.closed {
		return .Closed
	}
	if ptr.hooks == nil {
		panic("pool: not initialized")
	}
	if !slice.contains(ptr.hooks.ids[:], id) {
		panic("pool: foreign id")
	}
	return .Ok
}

@(private)
_pool_get_available_or_new :: proc(ptr: ^_Pool, id: int, m: ^MayItem) -> Pool_Get_Result {
	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)

	if res := _pool_check_ready(ptr, id); res != .Ok {
		return res
	}

	// Use stored item if available.
	if _, ok := ptr.lists[id]; ok && ptr.counts[id] > 0 {
		l := ptr.lists[id]
		raw := list.pop_front(&l)
		ptr.lists[id] = l
		ptr.counts[id] -= 1
		poly := cast(^PolyNode)raw
		polynode_reset(poly)
		m^ = poly
	}

	// Call on_get outside lock to reinit or create.
	h := ptr.hooks
	ctx := h.ctx
	count := ptr.counts[id]
	sync.mutex_unlock(&ptr.mutex)
	// 2DO [itc: hook-reentrancy-guard]: add @(thread_local) _pool_in_hook: bool guard
	// to detect pool_get/pool_put called re-entrantly from inside a hook.
	h.on_get(ctx, id, count, m)
	sync.mutex_lock(&ptr.mutex)

	return m^ != nil ? .Ok : .Not_Created
}

@(private)
_pool_get_new_only :: proc(ptr: ^_Pool, id: int, m: ^MayItem) -> Pool_Get_Result {
	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)

	if res := _pool_check_ready(ptr, id); res != .Ok {
		return res
	}

	// Always call on_get with m^ == nil to force creation.
	h := ptr.hooks
	ctx := h.ctx
	count := ptr.counts[id]
	sync.mutex_unlock(&ptr.mutex)
	// 2DO [itc: hook-reentrancy-guard]: add @(thread_local) _pool_in_hook: bool guard
	// to detect pool_get/pool_put called re-entrantly from inside a hook.
	h.on_get(ctx, id, count, m)
	sync.mutex_lock(&ptr.mutex)

	return m^ != nil ? .Ok : .Not_Created
}

@(private)
_pool_get_available_only :: proc(ptr: ^_Pool, id: int, m: ^MayItem) -> Pool_Get_Result {
	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)

	if res := _pool_check_ready(ptr, id); res != .Ok {
		return res
	}

	if _, ok := ptr.lists[id]; ok && ptr.counts[id] > 0 {
		l := ptr.lists[id]
		raw := list.pop_front(&l)
		ptr.lists[id] = l
		ptr.counts[id] -= 1
		poly := cast(^PolyNode)raw
		polynode_reset(poly)
		m^ = poly
		return .Ok
	}

	return .Not_Available
}

@(private)
_pool_get_wait_impl :: proc(ptr: ^_Pool, id: int, m: ^MayItem, timeout: time.Duration) -> Pool_Get_Result {
	infinite := timeout < 0
	start := time.now()

	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)

	for {
		if res := _pool_check_ready(ptr, id); res != .Ok {
			return res
		}

		if _, ok := ptr.lists[id]; ok && ptr.counts[id] > 0 {
			l := ptr.lists[id]
			raw := list.pop_front(&l)
			ptr.lists[id] = l
			ptr.counts[id] -= 1
			poly := cast(^PolyNode)raw
			polynode_reset(poly)
			m^ = poly
			return .Ok
		}

		if timeout == 0 {
			return .Not_Available
		}

		if !infinite {
			elapsed := time.since(start)
			if elapsed >= timeout {
				return .Not_Available
			}
			remaining := timeout - elapsed
			sync.cond_wait_with_timeout(&ptr.cond, &ptr.mutex, remaining)
		} else {
			sync.cond_wait(&ptr.cond, &ptr.mutex)
		}
	}
}

@(private)
_pool_put_impl :: proc(ptr: ^_Pool, node: ^PolyNode, id: int, m: ^MayItem) {
	sync.mutex_lock(&ptr.mutex)

	if ptr.closed {
		sync.mutex_unlock(&ptr.mutex)
		return // Caller retains ownership of m^.
	}

	if ptr.hooks == nil {
		sync.mutex_unlock(&ptr.mutex)
		panic("pool_put: pool not initialized")
	}

	if !slice.contains(ptr.hooks.ids[:], id) {
		sync.mutex_unlock(&ptr.mutex)
		panic("pool_put: foreign id")
	}

	count := ptr.counts[id]
	h := ptr.hooks
	ctx := h.ctx

	// Call on_put outside lock.
	sync.mutex_unlock(&ptr.mutex)
	// 2DO [itc: hook-reentrancy-guard]: add @(thread_local) _pool_in_hook: bool guard
	// to detect pool_get/pool_put called re-entrantly from inside a hook.
	h.on_put(ctx, count, m)
	sync.mutex_lock(&ptr.mutex)

	// If hook didn't dispose it, store it.
	if !ptr.closed && m^ != nil {
		l := ptr.lists[id]
		// Putting a linked node corrupts the list silently.
		// A loud panic here is cheaper than hunting corruption later.
		if polynode_is_linked(node) {
			sync.mutex_unlock(&ptr.mutex)
			panic("pool_put: node is still linked — detach before putting back")
		}
		list.push_front(&l, &node.node)
		ptr.lists[id] = l
		ptr.counts[id] += 1
		m^ = nil
		sync.cond_signal(&ptr.cond)
	}

	sync.mutex_unlock(&ptr.mutex)
}

@(private)
_pool_put_all_validate :: proc(ptr: ^_Pool, first: ^PolyNode) {
	sync.mutex_lock(&ptr.mutex)
	defer sync.mutex_unlock(&ptr.mutex)
	if ptr.hooks == nil {
		return
	}
	for n := first; n != nil; n = cast(^PolyNode)n.next {
		if n.id == 0 {
			panic("pool_put_all: id cannot be 0")
		}
		if !slice.contains(ptr.hooks.ids[:], n.id) {
			panic("pool_put_all: foreign id")
		}
	}
}

@(private)
_pool_put_all_exec :: proc(p: Pool, first: ^PolyNode, m: ^MayItem) {
	current := first
	for current != nil {
		next := cast(^PolyNode)current.next // capture before reset clears it
		polynode_reset(current)
		mi: MayItem = current
		pool_put(p, &mi)
		if mi != nil {
			// Pool closed — return remaining chain to caller.
			m^ = current
			return
		}
		current = next
	}
	m^ = nil
}

@(private)
_unwrap_pool :: proc(p: Pool) -> ^_Pool {
	return cast(^_Pool)p
}

@(private)
_pool_dispose :: proc(m: ^MayItem) {
	ptr, _ := m^.?
	p := cast(^_Pool)ptr
	if !p.closed {
		panic("matryoshka_dispose: pool must be closed first")
	}
	alloc := p.alctr
	delete(p.lists)
	delete(p.counts)
	free(p, alloc)
	m^ = nil
}
