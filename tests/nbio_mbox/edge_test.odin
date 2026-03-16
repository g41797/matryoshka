//+test
package nbio_mbox_tests

import nbio_mbox "../../nbio_mbox"
import loop_mbox "../../loop_mbox"
import examples "../../examples"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Package-level constants (Odin has no `const` keyword inside procs).
_TE_N :: 1_000
_BM_N_THREADS :: 20
_BM_N_PER :: 5_000
_BM_TOTAL :: _BM_N_THREADS * _BM_N_PER
_PC_N_ROUNDS :: 10
_PC_N_PER :: 1_000

// Context structs for nbio edge tests.
_TE_Ctx :: struct {
	m:    ^loop_mbox.Mbox(examples.Itm),
	msgs: []examples.Itm,
}

_BM_Ctx :: struct {
	m:    ^loop_mbox.Mbox(examples.Itm),
	slab: []examples.Itm,
}

_PC_Ctx :: struct {
	m:    ^loop_mbox.Mbox(examples.Itm),
	msgs: []examples.Itm,
}

_LA_Ctx :: struct {
	m:    ^loop_mbox.Mbox(examples.Itm),
	a:    ^examples.Itm,
	b:    ^examples.Itm,
	sema: ^sync.Sema,
}

// _test_nbio_throttle_efficiency: 1,000 sends from a worker thread; main drains with
// tick+try_receive. Verifies all messages are delivered for the given kind.
// The CAS throttling (.Timeout) prevents the 128-slot cross-thread queue from
// overflowing; a successful delivery pass proves the wake path works end-to-end.
@(private)
_test_nbio_throttle_efficiency :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
	if !testing.expect(
		t,
		nbio.acquire_thread_event_loop() == nil,
		"failed to acquire event loop",
	) {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(examples.Itm, loop, kind)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		loop_mbox.close(m)
		loop_mbox.destroy(m)
	}

	msgs := make([]examples.Itm, _TE_N)
	defer delete(msgs)
	for i in 0 ..< _TE_N {
		msgs[i] = examples.Itm {
			data = i,
		}
	}

	ctx := _TE_Ctx {
		m    = m,
		msgs = msgs,
	}
	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_TE_Ctx)(data)
		for i in 0 ..< len(c.msgs) {
			msg_opt: Maybe(^examples.Itm) = &c.msgs[i]
			loop_mbox.send(c.m, &msg_opt)
		}
	})

	received := 0
	for received < _TE_N {
		tick_err := nbio.tick(50 * time.Millisecond)
		if tick_err != nil {
			break
		}
		tb := loop_mbox.try_receive_batch(m)
		for node := list.pop_front(&tb); node != nil; node = list.pop_front(&tb) {
			received += 1
		}
	}

	thread.join(th)
	thread.destroy(th)

	// Drain any residual (stall window).
	tr := loop_mbox.try_receive_batch(m)
	for node := list.pop_front(&tr); node != nil; node = list.pop_front(&tr) {
		received += 1
	}

	testing.expect(t, received == _TE_N, "should receive all 1,000 messages")
}

@(test)
test_nbio_throttle_efficiency :: proc(t: ^testing.T) {
	_test_nbio_throttle_efficiency(t, .Timeout)
	_test_nbio_throttle_efficiency(t, .UDP)
}

// _test_nbio_burst_multiproducer: 20 threads × 5,000 sends = 100,000 total.
// Verifies 100% delivery under concurrent high-frequency sends.
@(private)
_test_nbio_burst_multiproducer :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
	if !testing.expect(
		t,
		nbio.acquire_thread_event_loop() == nil,
		"failed to acquire event loop",
	) {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(examples.Itm, loop, kind)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		loop_mbox.close(m)
		loop_mbox.destroy(m)
	}

	slabs := make([][]examples.Itm, _BM_N_THREADS)
	defer delete(slabs)
	for i in 0 ..< _BM_N_THREADS {
		slabs[i] = make([]examples.Itm, _BM_N_PER)
		for j in 0 ..< _BM_N_PER {
			slabs[i][j] = examples.Itm {
				data = i * _BM_N_PER + j,
			}
		}
	}
	defer for i in 0 ..< _BM_N_THREADS {
		delete(slabs[i])
	}

	ctxs := make([]_BM_Ctx, _BM_N_THREADS)
	defer delete(ctxs)
	threads := make([]^thread.Thread, _BM_N_THREADS)
	defer delete(threads)

	for i in 0 ..< _BM_N_THREADS {
		ctxs[i] = _BM_Ctx {
			m    = m,
			slab = slabs[i],
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_BM_Ctx)(data)
			for i in 0 ..< len(c.slab) {
				msg_opt: Maybe(^examples.Itm) = &c.slab[i]
				loop_mbox.send(c.m, &msg_opt)
			}
		})
	}

	received := 0
	for received < _BM_TOTAL {
		tick_err := nbio.tick(100 * time.Millisecond)
		if tick_err != nil {
			break
		}
		bb := loop_mbox.try_receive_batch(m)
		for node := list.pop_front(&bb); node != nil; node = list.pop_front(&bb) {
			received += 1
		}
	}

	for i in 0 ..< _BM_N_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	// Drain any residual.
	br := loop_mbox.try_receive_batch(m)
	for node := list.pop_front(&br); node != nil; node = list.pop_front(&br) {
		received += 1
	}

	testing.expect(t, received == _BM_TOTAL, "should receive all 100,000 messages")
}

@(test)
test_nbio_burst_multiproducer :: proc(t: ^testing.T) {
	_test_nbio_burst_multiproducer(t, .Timeout)
	_test_nbio_burst_multiproducer(t, .UDP)
}

// _test_nbio_pool_constancy: 10 rounds of 1,000 sends + full drain.
// Verifies no memory growth (tracking allocator catches leaks between rounds).
@(private)
_test_nbio_pool_constancy :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
	if !testing.expect(
		t,
		nbio.acquire_thread_event_loop() == nil,
		"failed to acquire event loop",
	) {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(examples.Itm, loop, kind)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		loop_mbox.close(m)
		loop_mbox.destroy(m)
	}

	msgs := make([]examples.Itm, _PC_N_PER)
	defer delete(msgs)

	for round in 0 ..< _PC_N_ROUNDS {
		for i in 0 ..< _PC_N_PER {
			msgs[i] = examples.Itm {
				data = round * _PC_N_PER + i,
			}
		}

		ctx := _PC_Ctx {
			m    = m,
			msgs = msgs,
		}
		th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
			c := (^_PC_Ctx)(data)
			for i in 0 ..< len(c.msgs) {
				msg_opt: Maybe(^examples.Itm) = &c.msgs[i]
				loop_mbox.send(c.m, &msg_opt)
			}
		})

		received := 0
		for received < _PC_N_PER {
			tick_err := nbio.tick(50 * time.Millisecond)
			if tick_err != nil {
				break
			}
			pb := loop_mbox.try_receive_batch(m)
			for node := list.pop_front(&pb); node != nil; node = list.pop_front(&pb) {
				received += 1
			}
		}

		thread.join(th)
		thread.destroy(th)

		// Drain residual.
		pr := loop_mbox.try_receive_batch(m)
		for node := list.pop_front(&pr); node != nil; node = list.pop_front(&pr) {
			received += 1
		}

		testing.expectf(
			t,
			received == _PC_N_PER,
			"round %d: expected %d messages, got %d",
			round,
			_PC_N_PER,
			received,
		)
	}
}

@(test)
test_nbio_pool_constancy :: proc(t: ^testing.T) {
	_test_nbio_pool_constancy(t, .Timeout)
	_test_nbio_pool_constancy(t, .UDP)
}

// _test_nbio_late_arrival: verifies a message arriving after wake_pending is cleared is delivered.
// Pattern: send A → tick → receive A → send B (CAS fires new timeout) → tick → receive B.
@(private)
_test_nbio_late_arrival :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
	if !testing.expect(
		t,
		nbio.acquire_thread_event_loop() == nil,
		"failed to acquire event loop",
	) {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(examples.Itm, loop, kind)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		loop_mbox.close(m)
		loop_mbox.destroy(m)
	}

	a := new(examples.Itm); a.data = 1
	b := new(examples.Itm); b.data = 2

	sema: sync.Sema
	ctx := _LA_Ctx {
		m    = m,
		a    = a,
		b    = b,
		sema = &sema,
	}

	th := thread.create_and_start_with_data(
	&ctx,
	proc(data: rawptr) {
		c := (^_LA_Ctx)(data)
		// Send A first, then wait until main signals, then send B.
		a_opt: Maybe(^examples.Itm) = c.a; loop_mbox.send(c.m, &a_opt)
		sync.sema_wait(c.sema)
		b_opt: Maybe(^examples.Itm) = c.b; loop_mbox.send(c.m, &b_opt)
	},
	)

	// Brief sleep so the spawned thread has time to schedule and send A.
	// On Windows .Timeout busy-polls (no keepalive), so the tick loop would
	// otherwise exhaust 200 iterations (~200 µs) before the thread even starts.
	time.sleep(20 * time.Millisecond)

	// Drain A via tick.
	got_a: ^examples.Itm
	for _ in 0 ..< 200 {
		nbio.tick(20 * time.Millisecond)
		lab := loop_mbox.try_receive_batch(m)
		node := list.pop_front(&lab)
		if node != nil {
			got_a = (^examples.Itm)(node)
			break
		}
	}
	testing.expect(t, got_a != nil && got_a.data == 1, "should receive message A")
	if got_a != nil {free(got_a)}

	// Signal worker to send B.
	sync.sema_post(&sema)

	// Join before draining B: on Windows .Timeout busy-polls, so the tick loop
	// may exhaust before the sender thread schedules. Joining ensures B is in
	// the queue before the final try_receive_batch.
	thread.join(th)
	thread.destroy(th)

	// Drain B.
	got_b: ^examples.Itm
	for _ in 0 ..< 200 {
		nbio.tick(20 * time.Millisecond)
		lbb := loop_mbox.try_receive_batch(m)
		node := list.pop_front(&lbb)
		if node != nil {
			got_b = (^examples.Itm)(node)
			break
		}
	}
	if got_b == nil {
		// Final fallback drain (B is guaranteed in queue after join).
		fb := loop_mbox.try_receive_batch(m)
		node := list.pop_front(&fb)
		if node != nil {got_b = (^examples.Itm)(node)}
	}
	testing.expect(t, got_b != nil && got_b.data == 2, "should receive message B after flag reset")
	if got_b != nil {free(got_b)}
}

@(test)
test_nbio_late_arrival :: proc(t: ^testing.T) {
	_test_nbio_late_arrival(t, .Timeout)
	_test_nbio_late_arrival(t, .UDP)
}
