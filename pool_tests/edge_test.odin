//+test


package pool_tests

import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import pool_pkg "../pool"

// ----------------------------------------------------------------------------
// Context types for threaded tests
// ----------------------------------------------------------------------------

// _Put_Wakes_Ctx holds shared state for test_pool_get_timeout_put_wakes.
_Put_Wakes_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Msg),
	msg:   ^Test_Msg,
	ready: sync.Sema,
}

// _Destroy_Wakes_Ctx holds shared state for test_pool_get_timeout_destroy_wakes.
_Destroy_Wakes_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Msg),
	ready: sync.Sema,
}

// _N_Pool_Ctx holds state for one thread in multi-waiter pool tests.
_N_Pool_Ctx :: struct {
	pool:    ^pool_pkg.Pool(Test_Msg),
	idx:     int,
	started: ^sync.Sema,
	done:    ^sync.Sema,
	result:  pool_pkg.Pool_Status,
	got:     ^Test_Msg,
}

// _Stress_Ctx holds state for stress test threads.
_Stress_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Msg),
	start: ^sync.Sema,
	done:  ^sync.Sema,
}

// _Max_Race_Ctx holds state for max-limit racing test threads.
_Max_Race_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Msg),
	start: ^sync.Sema,
	done:  ^sync.Sema,
}

// _Shutdown_Ctx holds state for shutdown race test threads.
_Shutdown_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Msg),
	start: ^sync.Sema,
	done:  ^sync.Sema,
}

// _Idempotent_Ctx holds state for idempotent destroy test threads.
_Idempotent_Ctx :: struct {
	pool:  ^pool_pkg.Pool(Test_Msg),
	start: ^sync.Sema,
}

// ----------------------------------------------------------------------------
// Moved from pool_test.odin: timeout and multi-waiter tests
// ----------------------------------------------------------------------------

@(test)
test_pool_get_timeout_elapsed :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)
	defer pool_pkg.destroy(&p)

	// Empty pool, .Pool_Only, short timeout — nobody puts, should expire with .Pool_Empty.
	msg, status := pool_pkg.get(&p, .Pool_Only, time.Millisecond)
	testing.expect(t, msg == nil, "msg should be nil after timeout")
	testing.expect(t, status == .Pool_Empty, "status should be .Pool_Empty after timeout")
}

@(test)
test_pool_get_timeout_put_wakes :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)
	defer pool_pkg.destroy(&p)

	// Pre-allocate a message to put back from the second thread.
	msg, _ := pool_pkg.get(&p)
	testing.expect(t, msg != nil, "initial get should return non-nil")
	if msg == nil {
		return
	}

	ctx := _Put_Wakes_Ctx {
		pool = &p,
		msg  = msg,
	}

	th := thread.create_and_start_with_data(
	&ctx,
	proc(data: rawptr) {
		c := (^_Put_Wakes_Ctx)(data)
		// Signal the waiter that we're ready, then put the message back.
		sync.sema_post(&c.ready)
		time.sleep(5 * time.Millisecond)
		pool_pkg.put(c.pool, c.msg)
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
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)

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
// Put 5 messages back after all threads are waiting.
// 5 threads must get .Ok, 5 must get .Pool_Empty.
@(test)
test_pool_many_waiters_partial_fill :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)
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

	// Pre-allocate 5 messages (sets allocator field), then put them back.
	// Each put wakes one waiting thread via cond_signal.
	pre_msgs: [5]^Test_Msg
	for i in 0 ..< 5 {
		pre_msgs[i], _ = pool_pkg.get(&p)
	}
	for i in 0 ..< 5 {
		pool_pkg.put(&p, pre_msgs[i])
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
	testing.expect(t, ok_count == 5, "5 threads should get a message")
	testing.expect(t, empty_count == 5, "5 threads should time out with .Pool_Empty")
}

// test_pool_destroy_wakes_all: 10 threads wait with infinite timeout.
// destroy() must wake all 10 with .Closed.
@(test)
test_pool_destroy_wakes_all :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)

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
// After all threads complete, destroy and verify no messages leaked.
@(test)
test_pool_stress_high_volume :: proc(t: ^testing.T) {
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)

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
				msg, _ := pool_pkg.get(c.pool)
				pool_pkg.put(c.pool, msg)
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
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, initial_msgs = 3, max_msgs = 3, reset = nil)

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
			msg, _ := pool_pkg.get(c.pool)
			if msg != nil {
				pool_pkg.put(c.pool, msg)
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
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, reset = nil)

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
				msg, status := pool_pkg.get(c.pool)
				if status != .Ok {
					break
				}
				pool_pkg.put(c.pool, msg)
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
	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, initial_msgs = 5, reset = nil)

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

	p: pool_pkg.Pool(Test_Msg)
	pool_pkg.init(&p, initial_msgs = 3, reset = nil, allocator = counting)
	// init consumed 3 allocs.
	testing.expect(t, data.count == 3, "init with 3 pre-alloc should consume 3 allocs")

	// Drain pre-alloc messages from pool — no new allocations.
	msg1, _ := pool_pkg.get(&p, .Pool_Only)
	msg2, _ := pool_pkg.get(&p, .Pool_Only)
	msg3, _ := pool_pkg.get(&p, .Pool_Only)
	testing.expect(t, data.count == 3, "draining pre-alloc should not increase alloc count")

	// Pool is now empty. get(.Always) forces 2 new allocations.
	msg4, _ := pool_pkg.get(&p)
	msg5, _ := pool_pkg.get(&p)
	testing.expect(t, data.count == 5, "2 fresh allocs should bring total to 5")
	testing.expect(t, msg4 != nil, "msg4 should be non-nil")
	testing.expect(t, msg5 != nil, "msg5 should be non-nil")

	// Put all 5 back.
	pool_pkg.put(&p, msg1)
	pool_pkg.put(&p, msg2)
	pool_pkg.put(&p, msg3)
	pool_pkg.put(&p, msg4)
	pool_pkg.put(&p, msg5)
	testing.expect(t, p.curr_msgs == 5, "all 5 messages should be in pool")

	// destroy frees all 5 via the counting allocator.
	pool_pkg.destroy(&p)
	testing.expect(t, data.count == 5, "alloc count should still be 5 after destroy")
	testing.expect(t, p.curr_msgs == 0, "curr_msgs should be 0 after destroy")
}
