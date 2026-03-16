//+test
package pool_tests

import list "core:container/intrusive/list"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"

import pool_pkg "../../pool"
import wakeup_pkg "../../wakeup"

// Test_Itm is the item type used in all pool tests.
// allocator field is required by the pool where clause.
Test_Itm :: struct {
	node:      list.Node,
	allocator: mem.Allocator, // required by pool where clause
	data:      int,
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

// failing_allocator always returns Out_Of_Memory.
_fail_alloc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	data: []byte,
	err: mem.Allocator_Error,
) {
	return nil, .Out_Of_Memory
}

failing_allocator :: mem.Allocator {
	procedure = _fail_alloc,
	data      = nil,
}

// Counting_Alloc_Data tracks allocations for the counting allocator.
Counting_Alloc_Data :: struct {
	max:     int,
	count:   int,
	backing: mem.Allocator,
}

// _counting_alloc succeeds for the first max alloc calls, then returns OOM.
_counting_alloc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	data: []byte,
	err: mem.Allocator_Error,
) {
	d := (^Counting_Alloc_Data)(allocator_data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if d.count >= d.max {
			return nil, .Out_Of_Memory
		}
		d.count += 1
	}
	return d.backing.procedure(d.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// _test_reset_bits records reset events in itm.data as bit flags:
//   bit 0 (1) = .Get was called
//   bit 1 (2) = .Put was called
// Concurrent-safe: each test uses its own item's data field.
_test_reset_bits :: proc(itm: ^Test_Itm, e: pool_pkg.Pool_Event) {
	switch e {
	case .Get:
		itm.data |= 1
	case .Put:
		itm.data |= 2
	}
}

// ----------------------------------------------------------------------------
// Existing tests (updated for new API)
// ----------------------------------------------------------------------------

@(test)
test_pool_get_always :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Empty pool, .Always strategy — must allocate a new item.
	itm, _ := pool_pkg.get(&p)
	testing.expect(t, itm != nil, "get(.Always) on empty pool should return non-nil")
	if itm != nil {
		free(itm, itm.allocator)
	}
}

@(test)
test_pool_get_pool_only :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Empty pool, .Pool_Only — must return nil.
	itm, _ := pool_pkg.get(&p, .Pool_Only)
	testing.expect(t, itm == nil, "get(.Pool_Only) on empty pool should return nil")
}

@(test)
test_pool_put_and_get :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Get a fresh item (sets itm.allocator), put it back, get again.
	orig, _ := pool_pkg.get(&p)
	testing.expect(t, orig != nil, "initial get should return non-nil")
	if orig == nil {
		return
	}
	orig.data = 42
	orig_opt: Maybe(^Test_Itm) = orig // [itc: maybe-container]
	pool_pkg.put(&p, &orig_opt) // [itc: defer-put]

	got, _ := pool_pkg.get(&p)
	testing.expect(t, got != nil, "get after put should return non-nil")
	testing.expect(t, got == orig, "get should return the same pointer that was put")
	testing.expect(t, got.data == 42, "data should be preserved after put/get round-trip")
	if got != nil {
		free(got, got.allocator)
	}
}

@(test)
test_pool_respects_max :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, max_msgs = 2, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Get 3 items from pool (sets allocator on each).
	itm1, _ := pool_pkg.get(&p)
	itm2, _ := pool_pkg.get(&p)
	itm3, _ := pool_pkg.get(&p)

	itm1_opt: Maybe(^Test_Itm) = itm1; pool_pkg.put(&p, &itm1_opt) // curr_msgs = 1
	itm2_opt: Maybe(^Test_Itm) = itm2; pool_pkg.put(&p, &itm2_opt) // curr_msgs = 2
	itm3_opt: Maybe(^Test_Itm) = itm3; pool_pkg.put(&p, &itm3_opt) // exceeds max — pool frees itm3

	testing.expect(t, p.curr_msgs == 2, "curr_msgs should stay at max after excess put")
}

@(test)
test_pool_preinit :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 4, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	testing.expect(t, p.curr_msgs == 4, "curr_msgs should be 4 after init with initial_msgs=4")

	// All 4 gets should return pre-allocated items.
	for _ in 0 ..< 4 {
		itm, _ := pool_pkg.get(&p, .Pool_Only)
		testing.expect(t, itm != nil, "pre-allocated get should return non-nil")
		if itm != nil {
			free(itm, itm.allocator)
		}
	}

	// Pool is now empty.
	fifth, _ := pool_pkg.get(&p, .Pool_Only)
	testing.expect(t, fifth == nil, "pool should be empty after 4 gets")
}

@(test)
test_pool_closed_get :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})

	// Get a fresh item (sets allocator), put it back into pool.
	itm, _ := pool_pkg.get(&p)
	itm_opt: Maybe(^Test_Itm) = itm
	pool_pkg.put(&p, &itm_opt)

	pool_pkg.destroy(&p) // marks closed, frees pool items

	got, _ := pool_pkg.get(&p)
	testing.expect(t, got == nil, "get on closed pool should return nil")
}

@(test)
test_pool_closed_put :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	pool_pkg.destroy(&p) // closed

	// Simulate a pool-owned item by setting allocator manually.
	itm := new(Test_Itm)
	itm.allocator = p.allocator // mark as pool-owned so put doesn't treat it as foreign
	itm_opt: Maybe(^Test_Itm) = itm
	pool_pkg.put(&p, &itm_opt) // pool is closed — frees itm, returns (nil, true)

	testing.expect(t, p.curr_msgs == 0, "curr_msgs should stay 0 after put on closed pool")
}

@(test)
test_pool_nil_put :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	nil_opt: Maybe(^Test_Itm) = nil
	pool_pkg.put(&p, &nil_opt) // no-op
	testing.expect(t, p.curr_msgs == 0, "curr_msgs should stay 0 after put(nil)")
}

@(test)
test_pool_destroy :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 2, hooks = pool_pkg.T_Hooks(Test_Itm){})

	pool_pkg.destroy(&p)

	got, _ := pool_pkg.get(&p)
	testing.expect(t, got == nil, "get after destroy should return nil")
	testing.expect(t, p.state == .Closed, "pool should be marked closed after destroy")
}

// ----------------------------------------------------------------------------
// New status tests
// ----------------------------------------------------------------------------

@(test)
test_pool_get_status_ok :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 1, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	itm, status := pool_pkg.get(&p)
	testing.expect(t, status == .Ok, "status should be .Ok")
	testing.expect(t, itm != nil, "itm should be non-nil")
	if itm != nil {
		free(itm, itm.allocator)
	}
}

@(test)
test_pool_get_status_pool_empty :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){}) // empty pool
	defer pool_pkg.destroy(&p)

	itm, status := pool_pkg.get(&p, .Pool_Only)
	testing.expect(t, status == .Pool_Empty, "status should be .Pool_Empty")
	testing.expect(t, itm == nil, "itm should be nil")
}

@(test)
test_pool_get_status_closed :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	pool_pkg.destroy(&p)

	itm, status := pool_pkg.get(&p)
	testing.expect(t, status == .Closed, "status should be .Closed")
	testing.expect(t, itm == nil, "itm should be nil")
}

@(test)
test_pool_get_status_uninit :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm) // zero value — state is .Uninit

	itm, status := pool_pkg.get(&p)
	testing.expect(t, status == .Closed, "uninit pool status should be .Closed")
	testing.expect(t, itm == nil, "itm should be nil")
}

@(test)
test_pool_get_status_oom :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	// init with 0 pre-allocs succeeds even with failing allocator
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){}, allocator = failing_allocator)
	defer pool_pkg.destroy(&p)

	// .Always on empty pool tries to allocate — fails
	itm, status := pool_pkg.get(&p)
	testing.expect(t, status == .Out_Of_Memory, "status should be .Out_Of_Memory")
	testing.expect(t, itm == nil, "itm should be nil")
}

// ----------------------------------------------------------------------------
// New init OOM tests
// ----------------------------------------------------------------------------

@(test)
test_pool_init_oom_immediate :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	ok, status := pool_pkg.init(&p, initial_msgs = 1, hooks = pool_pkg.T_Hooks(Test_Itm){}, allocator = failing_allocator)
	testing.expect(t, !ok, "init should fail")
	testing.expect(t, status == .Out_Of_Memory, "status should be .Out_Of_Memory")
	testing.expect(t, p.state == .Closed, "pool should be .Closed after failed init")
}

@(test)
test_pool_init_oom_partial :: proc(t: ^testing.T) {
	data := Counting_Alloc_Data {
		max     = 2,
		backing = context.allocator,
	}
	counting := mem.Allocator {
		procedure = _counting_alloc,
		data      = &data,
	}

	p: pool_pkg.Pool(Test_Itm)
	ok, status := pool_pkg.init(&p, initial_msgs = 4, hooks = pool_pkg.T_Hooks(Test_Itm){}, allocator = counting)
	testing.expect(t, !ok, "init should fail after 2 successes")
	testing.expect(t, status == .Out_Of_Memory, "status should be .Out_Of_Memory")
	testing.expect(t, p.state == .Closed, "pool should be .Closed after partial OOM")
}

// ----------------------------------------------------------------------------
// New put foreign/own tests
// ----------------------------------------------------------------------------

@(test)
test_pool_put_foreign_returned :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// An item whose allocator field is zero (not from this pool's get).
	foreign_itm := new(Test_Itm) // itm.allocator is zero-value, != p.allocator
	foreign_opt: Maybe(^Test_Itm) = foreign_itm
	ret, ok := pool_pkg.put(&p, &foreign_opt)
	testing.expect(t, ret == foreign_itm, "foreign item should be returned to caller")
	testing.expect(t, !ok, "put of foreign item should return false")
	if ret != nil {
		free(ret) // caller must free it
	}
}

@(test)
test_pool_put_own_nil_return :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	itm, _ := pool_pkg.get(&p) // get sets itm.allocator = p.allocator
	testing.expect(t, itm != nil, "get should return non-nil")
	if itm == nil {
		return
	}
	itm_opt: Maybe(^Test_Itm) = itm
	ret, ok := pool_pkg.put(&p, &itm_opt)
	testing.expect(t, ret == nil, "put of own item should return nil")
	testing.expect(t, ok, "put of own item should return true")
}

// ----------------------------------------------------------------------------
// New reset proc tests
// ----------------------------------------------------------------------------

@(test)
test_pool_reset_on_get_recycled :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	// Pre-allocate 1 item so first get is from free-list (recycled).
	pool_pkg.init(&p, initial_msgs = 1, hooks = pool_pkg.T_Hooks(Test_Itm){ reset = _test_reset_bits })
	defer pool_pkg.destroy(&p)

	itm, _ := pool_pkg.get(&p) // recycled from free-list → reset(.Get) sets bit 0
	testing.expect(t, itm != nil, "get should return non-nil")
	if itm != nil {
		testing.expect(t, itm.data & 1 != 0, "get-reset bit should be set (bit 0)")
		testing.expect(t, itm.data & 2 == 0, "put-reset bit should NOT be set")
		free(itm, itm.allocator)
	}
}

@(test)
test_pool_reset_not_on_fresh :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){ reset = _test_reset_bits }) // empty pool
	defer pool_pkg.destroy(&p)

	itm, _ := pool_pkg.get(&p) // fresh allocation — reset must NOT be called
	testing.expect(t, itm != nil, "get should return non-nil")
	if itm != nil {
		testing.expect(
			t,
			itm.data == 0,
			"reset should NOT be called for fresh allocation (data must stay 0)",
		)
		free(itm, itm.allocator)
	}
}

@(test)
test_pool_reset_on_put :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){ reset = _test_reset_bits })
	defer pool_pkg.destroy(&p)

	itm, _ := pool_pkg.get(&p) // fresh alloc, no reset → data=0
	testing.expect(t, itm != nil, "get should return non-nil")
	if itm == nil {
		return
	}
	itm.data = 0 // so we have a clean state

	itm_opt: Maybe(^Test_Itm) = itm
	ret, _ := pool_pkg.put(&p, &itm_opt) // reset(.Put) sets bit 1 → data=2, then recycled
	testing.expect(t, ret == nil, "put should return nil for own item")

	// Get the recycled item back to inspect data.
	recycled, _ := pool_pkg.get(&p) // reset(.Get) sets bit 0 → data=3
	testing.expect(t, recycled != nil, "should get the recycled item back")
	if recycled != nil {
		testing.expect(t, recycled.data & 2 != 0, "put-reset bit should be set (bit 1)")
		free(recycled, recycled.allocator)
	}
}

// ----------------------------------------------------------------------------
// Timeout tests
// ----------------------------------------------------------------------------

@(test)
test_pool_get_timeout_zero :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Empty pool, .Pool_Only, timeout=0 — must return immediately with .Pool_Empty.
	itm, status := pool_pkg.get(&p, .Pool_Only, 0)
	testing.expect(t, itm == nil, "itm should be nil")
	testing.expect(t, status == .Pool_Empty, "status should be .Pool_Empty")
}

// ----------------------------------------------------------------------------
// WakeUper tests
// ----------------------------------------------------------------------------

// test_pool_waker_wakes_on_put: get(.Pool_Only,0) sets flag, put into empty pool calls wake.
@(test)
test_pool_waker_wakes_on_put :: proc(t: ^testing.T) {
	woke: sync.Sema
	waker := wakeup_pkg.WakeUper {
		ctx = rawptr(&woke),
		wake = proc(ctx: rawptr) {sync.sema_post((^sync.Sema)(ctx))},
		close = proc(ctx: rawptr) {},
	}

	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){}, waker = waker)
	defer pool_pkg.destroy(&p)

	// Non-blocking get on empty pool — sets empty_was_returned.
	itm, status := pool_pkg.get(&p, .Pool_Only, 0)
	testing.expect(t, itm == nil, "itm should be nil")
	testing.expect(t, status == .Pool_Empty, "status should be .Pool_Empty")

	// Put an item — pool transitions empty→non-empty, wake must fire.
	new_itm, _ := pool_pkg.get(&p) // .Always — allocates fresh
	new_itm_opt: Maybe(^Test_Itm) = new_itm
	pool_pkg.put(&p, &new_itm_opt)

	got_wake := sync.sema_wait_with_timeout(&woke, time.Second)
	testing.expect(t, got_wake, "waker.wake should be called when put fills an empty pool")
}

// test_pool_waker_close_on_destroy: destroy calls waker.close to free resources.
@(test)
test_pool_waker_close_on_destroy :: proc(t: ^testing.T) {
	closed: bool
	waker := wakeup_pkg.WakeUper {
		ctx = rawptr(&closed),
		wake = proc(ctx: rawptr) {},
		close = proc(ctx: rawptr) {(^bool)(ctx)^ = true},
	}

	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){}, waker = waker)

	pool_pkg.destroy(&p)

	testing.expect(t, closed, "waker.close should be called on destroy")
}

// ----------------------------------------------------------------------------
// Re-init and length tests
// ----------------------------------------------------------------------------

// test_pool_reinit_active: calling init on an Active pool must return (false, .Closed).
// Existing items must be unaffected.
@(test)
test_pool_reinit_active :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 3, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	ok, status := pool_pkg.init(&p, initial_msgs = 5, hooks = pool_pkg.T_Hooks(Test_Itm){})
	testing.expect(t, !ok, "re-init on active pool should fail")
	testing.expect(t, status == .Closed, "status should be .Closed for re-init on active pool")
	testing.expect(
		t,
		p.curr_msgs == 3,
		"existing items should be unaffected after rejected re-init",
	)
}

// test_pool_length: length reflects free-list size after init, get, and put.
@(test)
test_pool_length :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 3, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	testing.expect(t, pool_pkg.length(&p) == 3, "length should be 3 after init with 3 pre-alloc")

	itm, _ := pool_pkg.get(&p, .Pool_Only)
	testing.expect(t, itm != nil, "get should return non-nil")
	testing.expect(t, pool_pkg.length(&p) == 2, "length should be 2 after one get")

	itm_opt: Maybe(^Test_Itm) = itm
	pool_pkg.put(&p, &itm_opt)
	testing.expect(t, pool_pkg.length(&p) == 3, "length should be 3 after put back")
}
