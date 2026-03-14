// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package tests

import "core:testing"
import "core:thread"
import "core:time"
import "core:nbio"
import "core:sync"
import mbox ".."
import try_mbox "../try_mbox"

// Package-level constants (Odin has no `const` keyword inside procs).
_TE_N         :: 1_000
_BM_N_THREADS :: 20
_BM_N_PER     :: 5_000
_BM_TOTAL     :: _BM_N_THREADS * _BM_N_PER
_PC_N_ROUNDS  :: 10
_PC_N_PER     :: 1_000

// Context structs for nbio edge tests.
_TE_Ctx :: struct {
	m:    ^try_mbox.Mbox(Msg),
	msgs: []Msg,
}

_BM_Ctx :: struct {
	m:    ^try_mbox.Mbox(Msg),
	slab: []Msg,
}

_PC_Ctx :: struct {
	m:    ^try_mbox.Mbox(Msg),
	msgs: []Msg,
}

_LA_Ctx :: struct {
	m:    ^try_mbox.Mbox(Msg),
	a:    ^Msg,
	b:    ^Msg,
	sema: ^sync.Sema,
}

// test_nbio_throttle_efficiency: 1,000 sends from a worker thread; main drains with
// tick+try_receive. Asserts < 50 tick iterations, proving wake_pending throttling is active.
@(test)
test_nbio_throttle_efficiency :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msgs := make([]Msg, _TE_N)
	defer delete(msgs)
	for i in 0 ..< _TE_N {
		msgs[i] = Msg{data = i}
	}

	ctx := _TE_Ctx{m = m, msgs = msgs}
	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_TE_Ctx)(data)
		for i in 0 ..< len(c.msgs) {
			try_mbox.send(c.m, &c.msgs[i])
		}
	})

	received := 0
	tick_count := 0
	for received < _TE_N {
		tick_err := nbio.tick(50 * time.Millisecond)
		tick_count += 1
		if tick_err != nil {
			break
		}
		for {
			_, ok := try_mbox.try_receive(m)
			if !ok {break}
			received += 1
		}
	}

	thread.join(th)
	thread.destroy(th)

	// Drain any residual (stall window).
	for {
		_, ok := try_mbox.try_receive(m)
		if !ok {break}
		received += 1
	}

	testing.expect(t, received == _TE_N, "should receive all 1,000 messages")
	testing.expect(t, tick_count < 50, "tick count should be < 50 with wake_pending throttling")
}

// test_nbio_burst_multiproducer: 20 threads × 5,000 sends = 100,000 total.
// Verifies 100% delivery under concurrent high-frequency sends.
@(test)
test_nbio_burst_multiproducer :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	slabs := make([][]Msg, _BM_N_THREADS)
	defer delete(slabs)
	for i in 0 ..< _BM_N_THREADS {
		slabs[i] = make([]Msg, _BM_N_PER)
		for j in 0 ..< _BM_N_PER {
			slabs[i][j] = Msg{data = i * _BM_N_PER + j}
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
		ctxs[i] = _BM_Ctx{m = m, slab = slabs[i]}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_BM_Ctx)(data)
			for i in 0 ..< len(c.slab) {
				try_mbox.send(c.m, &c.slab[i])
			}
		})
	}

	received := 0
	for received < _BM_TOTAL {
		tick_err := nbio.tick(100 * time.Millisecond)
		if tick_err != nil {
			break
		}
		for {
			_, ok := try_mbox.try_receive(m)
			if !ok {break}
			received += 1
		}
	}

	for i in 0 ..< _BM_N_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	// Drain any residual.
	for {
		_, ok := try_mbox.try_receive(m)
		if !ok {break}
		received += 1
	}

	testing.expect(t, received == _BM_TOTAL, "should receive all 100,000 messages")
}

// test_nbio_pool_constancy: 10 rounds of 1,000 sends + full drain.
// Verifies no memory growth (tracking allocator catches leaks between rounds).
@(test)
test_nbio_pool_constancy :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msgs := make([]Msg, _PC_N_PER)
	defer delete(msgs)

	for round in 0 ..< _PC_N_ROUNDS {
		for i in 0 ..< _PC_N_PER {
			msgs[i] = Msg{data = round * _PC_N_PER + i}
		}

		ctx := _PC_Ctx{m = m, msgs = msgs}
		th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
			c := (^_PC_Ctx)(data)
			for i in 0 ..< len(c.msgs) {
				try_mbox.send(c.m, &c.msgs[i])
			}
		})

		received := 0
		for received < _PC_N_PER {
			tick_err := nbio.tick(50 * time.Millisecond)
			if tick_err != nil {
				break
			}
			for {
				_, ok := try_mbox.try_receive(m)
				if !ok {break}
				received += 1
			}
		}

		thread.join(th)
		thread.destroy(th)

		// Drain residual.
		for {
			_, ok := try_mbox.try_receive(m)
			if !ok {break}
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

// test_nbio_late_arrival: verifies a message arriving after wake_pending is cleared is delivered.
// Pattern: send A → tick → receive A → send B (CAS fires new timeout) → tick → receive B.
@(test)
test_nbio_late_arrival :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	a := Msg{data = 1}
	b := Msg{data = 2}

	sema: sync.Sema
	ctx := _LA_Ctx{m = m, a = &a, b = &b, sema = &sema}

	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_LA_Ctx)(data)
		// Send A first, then wait until main signals, then send B.
		try_mbox.send(c.m, c.a)
		sync.sema_wait(c.sema)
		try_mbox.send(c.m, c.b)
	})

	// Drain A via tick.
	got_a: ^Msg
	for _ in 0 ..< 200 {
		nbio.tick(20 * time.Millisecond)
		got, ok := try_mbox.try_receive(m)
		if ok {
			got_a = got
			break
		}
	}
	testing.expect(t, got_a != nil && got_a.data == 1, "should receive message A")

	// Signal worker to send B.
	sync.sema_post(&sema)

	// Drain B via tick.
	got_b: ^Msg
	for _ in 0 ..< 200 {
		nbio.tick(20 * time.Millisecond)
		got, ok := try_mbox.try_receive(m)
		if ok {
			got_b = got
			break
		}
	}
	testing.expect(t, got_b != nil && got_b.data == 2, "should receive message B after flag reset")

	thread.join(th)
	thread.destroy(th)
}
