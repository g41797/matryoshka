//+test


package pool_tests

import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import pool_pkg "../../pool"

// ----------------------------------------------------------------------------
// Context types for threaded tests
// ----------------------------------------------------------------------------

// _Put_Wakes_Ctx holds shared state for test_pool_get_timeout_put_wakes.
_Put_Wakes_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Itm),
	itm:   ^Test_Itm,
	ready: sync.Sema,
}

// _Destroy_Wakes_Ctx holds shared state for test_pool_get_timeout_destroy_wakes.
_Destroy_Wakes_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Itm),
	ready: sync.Sema,
}

// _N_Pool_Ctx holds state for one thread in multi-waiter pool tests.
_N_Pool_Ctx :: struct {
	pool:    ^pool_pkg.Pool(Test_Itm),
	idx:     int,
	started: ^sync.Sema,
	done:    ^sync.Sema,
	result:  pool_pkg.Pool_Status,
	got:     ^Test_Itm,
}

// _Stress_Ctx holds state for stress test threads.
_Stress_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Itm),
	start: ^sync.Sema,
	done:  ^sync.Sema,
}

// _Max_Race_Ctx holds state for max-limit racing test threads.
_Max_Race_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Itm),
	start: ^sync.Sema,
	done:  ^sync.Sema,
}

// _Shutdown_Ctx holds state for shutdown race test threads.
_Shutdown_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Itm),
	start: ^sync.Sema,
	done:  ^sync.Sema,
}

// _Idempotent_Ctx holds state for idempotent destroy test threads.
_Idempotent_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Itm),
	start: ^sync.Sema,
}

// ----------------------------------------------------------------------------
// Moved from pool_test.odin: timeout and multi-waiter tests
// ----------------------------------------------------------------------------

@(test)
test_pool_get_timeout_elapsed :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Empty pool, .Pool_Only, short timeout — nobody puts, should expire with .Pool_Empty.
	itm, status := pool_pkg.get(&p, .Pool_Only, time.Millisecond)
	testing.expect(t, itm == nil, "itm should be nil after timeout")
	testing.expect(t, status == .Pool_Empty, "status should be .Pool_Empty after timeout")
}

@(test)
test_pool_get_timeout_put_wakes :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	// Pre-allocate an item to put back from the second thread.
	itm, _ := pool_pkg.get(&p)
	testing.expect(t, itm != nil, "initial get should return non-nil")
	if itm == nil {
		return
	}

	ctx := _Put_Wakes_Ctx {
		pool = &p,
		itm  = itm,
	}

	th := thread.create_and_start_with_data(
	&ctx,
	proc(data: rawptr) {
		c := (^_Put_Wakes_Ctx)(data)
		// Signal the waiter that we're ready, then put the item back.
		sync.sema_post(&c.ready)
		time.sleep(5 * time.Millisecond)
		c_itm_opt: Maybe(^Test_Itm) = c.itm
		pool_pkg.put(c.pool, &c_itm_opt)
	},
	)

	// Wait until the thread is running, then block on get with a long timeout.
	sync.sema_wait(&ctx.ready)
	got, status := pool_pkg.get(&p, .Pool_Only, time.Second)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, got != nil, "get should return non-nil after put wakes it")
	testing.expect(t, status == .Ok, "status should be .Ok")
	if got != nil {
		free(got, got.allocator)
	}
}

@(test)
test_pool_get_timeout_destroy_wakes :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})

	ctx := _Destroy_Wakes_Ctx {
		pool = &p,
	}

	th := thread.create_and_start_with_data(
	&ctx,
	proc(data: rawptr) {
		c := (^_Destroy_Wakes_Ctx)(data)
		// Signal the waiter that we're running, then destroy the pool.
		sync.sema_post(&c.ready)
		time.sleep(5 * time.Millisecond)
		pool_pkg.destroy(c.pool)
	},
	)

	// Wait until the thread is running, then block on get with infinite timeout.
	sync.sema_wait(&ctx.ready)
	got, status := pool_pkg.get(&p, .Pool_Only, -1)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, got == nil, "get should return nil when pool is destroyed")
	testing.expect(t, status == .Closed, "status should be .Closed")
}

// test_pool_many_waiters_partial_fill: 10 threads wait with 2s timeout.
// Put 5 items back after all threads are waiting.
// 5 threads must get .Ok, 5 must get .Pool_Empty.
@(test)
test_pool_many_waiters_partial_fill :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})
	defer pool_pkg.destroy(&p)

	N :: 10
	started: sync.Sema
	done: sync.Sema
	ctxs: [N]_N_Pool_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _N_Pool_Ctx {
			pool    = &p,
			idx     = i,
			started = &started,
			done    = &done,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_N_Pool_Ctx)(data)
			sync.sema_post(c.started)
			c.got, c.result = pool_pkg.get(c.pool, .Pool_Only, 2 * time.Second)
			sync.sema_post(c.done)
		})
	}

	// Wait for all threads to be running and ready.
	for _ in 0 ..< N {
		sync.sema_wait(&started)
	}
	time.sleep(20 * time.Millisecond)

	// Pre-allocate 5 items (sets allocator field), then put them back.
	// Each put wakes one waiting thread via cond_signal.
	pre_itms: [5]^Test_Itm
	for i in 0 ..< 5 {
		pre_itms[i], _ = pool_pkg.get(&p)
	}
	for i in 0 ..< 5 {
		pre_opt: Maybe(^Test_Itm) = pre_itms[i]
		pool_pkg.put(&p, &pre_opt)
	}

	for _ in 0 ..< N {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	ok_count := 0
	empty_count := 0
	for i in 0 ..< N {
		#partial switch ctxs[i].result {
		case .Ok:
			ok_count += 1
			if ctxs[i].got != nil {
				free(ctxs[i].got, ctxs[i].got.allocator)
			}
		case .Pool_Empty:
			empty_count += 1
		}
	}
	testing.expect(t, ok_count == 5, "5 threads should get an item")
	testing.expect(t, empty_count == 5, "5 threads should time out with .Pool_Empty")
}

// test_pool_destroy_wakes_all: 10 threads wait with infinite timeout.
// destroy() must wake all 10 with .Closed.
@(test)
test_pool_destroy_wakes_all :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})

	N :: 10
	started: sync.Sema
	done: sync.Sema
	ctxs: [N]_N_Pool_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _N_Pool_Ctx {
			pool    = &p,
			idx     = i,
			started = &started,
			done    = &done,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_N_Pool_Ctx)(data)
			sync.sema_post(c.started)
			c.got, c.result = pool_pkg.get(c.pool, .Pool_Only, -1)
			sync.sema_post(c.done)
		})
	}

	// Wait for all threads to be running and ready.
	for _ in 0 ..< N {
		sync.sema_wait(&started)
	}
	time.sleep(20 * time.Millisecond)

	pool_pkg.destroy(&p)

	for _ in 0 ..< N {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	closed_count := 0
	for i in 0 ..< N {
		if ctxs[i].result == .Closed {
			closed_count += 1
		}
	}
	testing.expect(t, closed_count == 10, "all 10 threads should get .Closed after destroy")
}

// ----------------------------------------------------------------------------
// New stress and edge tests
// ----------------------------------------------------------------------------

// test_pool_stress_high_volume: 10 threads each do 1000 get(.Always)+put cycles.
// After all threads complete, destroy and verify no items leaked.
@(test)
test_pool_stress_high_volume :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})

	N :: 10
	start: sync.Sema
	done: sync.Sema
	ctxs: [N]_Stress_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Stress_Ctx {
			pool  = &p,
			start = &start,
			done  = &done,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Stress_Ctx)(data)
			sync.sema_wait(c.start)
			for _ in 0 ..< 1000 {
				itm, _ := pool_pkg.get(c.pool)
				itm_opt: Maybe(^Test_Itm) = itm
				pool_pkg.put(c.pool, &itm_opt)
			}
			sync.sema_post(c.done)
		})
	}

	// Release all threads simultaneously.
	for _ in 0 ..< N {
		sync.sema_post(&start)
	}
	for _ in 0 ..< N {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	pool_pkg.destroy(&p)
	testing.expect(t, p.curr_msgs == 0, "curr_msgs should be 0 after destroy")
}

// test_pool_max_limit_racing: 10 threads concurrently get then put.
// Pool has max_msgs=3. curr_msgs must never exceed cap.
@(test)
test_pool_max_limit_racing :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 3, max_msgs = 3, hooks = pool_pkg.T_Hooks(Test_Itm){})

	N :: 10
	start: sync.Sema
	done: sync.Sema
	ctxs: [N]_Max_Race_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Max_Race_Ctx {
			pool  = &p,
			start = &start,
			done  = &done,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Max_Race_Ctx)(data)
			sync.sema_wait(c.start)
			itm, _ := pool_pkg.get(c.pool)
			if itm != nil {
				itm_opt: Maybe(^Test_Itm) = itm
				pool_pkg.put(c.pool, &itm_opt)
			}
			sync.sema_post(c.done)
		})
	}

	for _ in 0 ..< N {
		sync.sema_post(&start)
	}
	for _ in 0 ..< N {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	testing.expect(
		t,
		p.curr_msgs <= 3,
		"curr_msgs should not exceed max_msgs after concurrent puts",
	)
	pool_pkg.destroy(&p)
}

// test_pool_shutdown_race: 5 threads loop get+put while main thread destroys.
// Verifies no panic, no deadlock, state == .Closed after join.
@(test)
test_pool_shutdown_race :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, hooks = pool_pkg.T_Hooks(Test_Itm){})

	N :: 5
	start: sync.Sema
	done: sync.Sema
	ctxs: [N]_Shutdown_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Shutdown_Ctx {
			pool  = &p,
			start = &start,
			done  = &done,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Shutdown_Ctx)(data)
			sync.sema_wait(c.start)
			for {
				itm, status := pool_pkg.get(c.pool)
				if status != .Ok {
					break
				}
				itm_opt: Maybe(^Test_Itm) = itm
				pool_pkg.put(c.pool, &itm_opt)
			}
			sync.sema_post(c.done)
		})
	}

	for _ in 0 ..< N {
		sync.sema_post(&start)
	}
	time.sleep(5 * time.Millisecond)
	pool_pkg.destroy(&p)

	for _ in 0 ..< N {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	testing.expect(t, p.state == .Closed, "pool should be .Closed after destroy")
}

// test_pool_idempotent_destroy: 10 threads all call destroy simultaneously.
// Verifies no crash, state == .Closed, curr_msgs == 0.
@(test)
test_pool_idempotent_destroy :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 5, hooks = pool_pkg.T_Hooks(Test_Itm){})

	N :: 10
	start: sync.Sema
	ctxs: [N]_Idempotent_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Idempotent_Ctx {
			pool  = &p,
			start = &start,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Idempotent_Ctx)(data)
			sync.sema_wait(c.start)
			pool_pkg.destroy(c.pool)
		})
	}

	for _ in 0 ..< N {
		sync.sema_post(&start)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	testing.expect(t, p.state == .Closed, "pool should be .Closed after concurrent destroys")
	testing.expect(t, p.curr_msgs == 0, "curr_msgs should be 0 after destroy")
}

// test_pool_allocator_integrity: verifies the pool uses its stored allocator for all
// new/free calls, never falling back to context.allocator.
@(test)
test_pool_allocator_integrity :: proc(t: ^testing.T) {
	data := Counting_Alloc_Data {
		max     = 10,
		backing = context.allocator,
	}
	counting := mem.Allocator {
		procedure = _counting_alloc,
		data      = &data,
	}

	p: pool_pkg.Pool(Test_Itm)
	pool_pkg.init(&p, initial_msgs = 3, hooks = pool_pkg.T_Hooks(Test_Itm){}, allocator = counting)
	// init consumed 3 allocs.
	testing.expect(t, data.count == 3, "init with 3 pre-alloc should consume 3 allocs")

	// Drain pre-alloc items from pool — no new allocations.
	itm1, _ := pool_pkg.get(&p, .Pool_Only)
	itm2, _ := pool_pkg.get(&p, .Pool_Only)
	itm3, _ := pool_pkg.get(&p, .Pool_Only)
	testing.expect(t, data.count == 3, "draining pre-alloc should not increase alloc count")

	// Pool is now empty. get(.Always) forces 2 new allocations.
	itm4, _ := pool_pkg.get(&p)
	itm5, _ := pool_pkg.get(&p)
	testing.expect(t, data.count == 5, "2 fresh allocs should bring total to 5")
	testing.expect(t, itm4 != nil, "itm4 should be non-nil")
	testing.expect(t, itm5 != nil, "itm5 should be non-nil")

	// Put all 5 back.
	itm1_opt: Maybe(^Test_Itm) = itm1; pool_pkg.put(&p, &itm1_opt)
	itm2_opt: Maybe(^Test_Itm) = itm2; pool_pkg.put(&p, &itm2_opt)
	itm3_opt: Maybe(^Test_Itm) = itm3; pool_pkg.put(&p, &itm3_opt)
	itm4_opt: Maybe(^Test_Itm) = itm4; pool_pkg.put(&p, &itm4_opt)
	itm5_opt: Maybe(^Test_Itm) = itm5; pool_pkg.put(&p, &itm5_opt)
	testing.expect(t, p.curr_msgs == 5, "all 5 items should be in pool")

	// destroy frees all 5 via the counting allocator.
	pool_pkg.destroy(&p)
	testing.expect(t, data.count == 5, "alloc count should still be 5 after destroy")
	testing.expect(t, p.curr_msgs == 0, "curr_msgs should be 0 after destroy")
}
