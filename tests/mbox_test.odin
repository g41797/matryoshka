package tests

import "base:intrinsics"
import "core:testing"
import "core:thread"
import "core:time"
import "core:sync"
import list "core:container/intrusive/list"
import mbox "../mbox"

// Msg is the local test message type.
Msg :: struct {
	node: list.Node,
	data: int,
}

// _Multi_Waiter_Ctx holds state for one thread in multi-waiter tests.
_Multi_Waiter_Ctx :: struct {
	mb:     ^mbox.Mailbox(Msg),
	result: mbox.Mailbox_Error,
	done:   ^sync.Sema,
}

// _Sender_Ctx holds state for one sender thread in test_heavy_racing.
_Sender_Ctx :: struct {
	mb:   ^mbox.Mailbox(Msg),
	msgs: []Msg,
}

// _Receiver_Ctx holds state for one receiver thread in test_heavy_racing.
_Receiver_Ctx :: struct {
	mb:       ^mbox.Mailbox(Msg),
	received: ^int,
}

// ----------------------------------------------------------------------------
// Mbox edge-case tests (moved from all_test.odin)
// ----------------------------------------------------------------------------

@(test)
test_send_and_receive :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	m := new(Msg); m.data = 42

	ok := mbox.send(&mb, m)
	testing.expect(t, ok, "send should return true")

	got, err := mbox.wait_receive(&mb, 0)
	testing.expect(t, err == .None, "wait_receive should return .None")
	testing.expect(t, got != nil && got.data == 42, "wait_receive wrong data")
	if got != nil {free(got)}
}

@(test)
test_empty_returns_timeout :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	got, err := mbox.wait_receive(&mb, 0)
	testing.expect(t, err == .Timeout, "empty mailbox should return .Timeout")
	testing.expect(t, got == nil, "empty mailbox should return nil message")
}

@(test)
test_timeout_on_empty :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	_, err := mbox.wait_receive(&mb, 10 * time.Millisecond)
	testing.expect(t, err == .Timeout, "wait_receive on empty mailbox should timeout")
}

@(test)
test_zero_timeout :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	_, err := mbox.wait_receive(&mb, 0)
	testing.expect(t, err == .Timeout, "wait_receive with timeout=0 should return .Timeout immediately")
}

@(test)
test_close_blocks_send :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	m := new(Msg); m.data = 1; defer free(m)

	_, _ = mbox.close(&mb)

	ok := mbox.send(&mb, m)
	testing.expect(t, !ok, "send to closed mailbox should return false")
}

@(test)
test_close_wakes_waiter :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	result: mbox.Mailbox_Error
	done: sync.Sema

	// Start a waiter thread.
	thread.run_with_poly_data3(&mb, &result, &done, proc(mb: ^mbox.Mailbox(Msg), result: ^mbox.Mailbox_Error, done: ^sync.Sema) {
		_, err := mbox.wait_receive(mb)
		result^ = err
		sync.sema_post(done)
	})

	time.sleep(10 * time.Millisecond)
	_, _ = mbox.close(&mb)

	sync.sema_wait(&done)
	testing.expect(t, result == .Closed, "waiter should get .Closed after close()")
}

@(test)
test_close_returns_remaining :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	a := new(Msg); a.data = 10
	b := new(Msg); b.data = 20

	mbox.send(&mb, a)
	mbox.send(&mb, b)

	remaining, was_open := mbox.close(&mb)
	testing.expect(t, was_open, "first close should return was_open=true")

	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		free((^Msg)(node))
		count += 1
	}
	testing.expect(t, count == 2, "close should return 2 remaining messages")
}

@(test)
test_double_close :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	_, was_open1 := mbox.close(&mb)
	_, was_open2 := mbox.close(&mb)
	testing.expect(t, was_open1, "first close should return was_open=true")
	testing.expect(t, !was_open2, "second close should return was_open=false")
}

@(test)
test_interrupt_wakes_waiter :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	result: mbox.Mailbox_Error
	done: sync.Sema

	// Start a waiter thread.
	thread.run_with_poly_data3(&mb, &result, &done, proc(mb: ^mbox.Mailbox(Msg), result: ^mbox.Mailbox_Error, done: ^sync.Sema) {
		_, err := mbox.wait_receive(mb)
		result^ = err
		sync.sema_post(done)
	})

	// Wait a bit so the thread is actually waiting.
	time.sleep(10 * time.Millisecond)
	ok := mbox.interrupt(&mb)
	testing.expect(t, ok, "interrupt should return true on first call")

	// Wait for the thread to finish processing.
	sync.sema_wait(&done)
	testing.expect(t, result == .Interrupted, "waiter should get .Interrupted after interrupt()")

	// Flag is self-cleared — second interrupt() should succeed now
	ok2 := mbox.interrupt(&mb)
	testing.expect(t, ok2, "interrupt should return true after flag was cleared by receiver")
}

@(test)
test_double_interrupt :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	ok1 := mbox.interrupt(&mb)
	ok2 := mbox.interrupt(&mb)
	testing.expect(t, ok1, "first interrupt should return true")
	testing.expect(t, !ok2, "second interrupt should return false — already interrupted")
}

@(test)
test_interrupt_on_closed :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	_, _ = mbox.close(&mb)
	ok := mbox.interrupt(&mb)
	testing.expect(t, !ok, "interrupt on closed mailbox should return false")
}

@(test)
test_reuse_via_zero :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	m := new(Msg); m.data = 7

	_, _ = mbox.close(&mb)
	mb = {} // reinitialize — safe after no waiters

	ok := mbox.send(&mb, m)
	testing.expect(t, ok, "send after reinitialization should succeed")

	got, err2 := mbox.wait_receive(&mb, 0)
	testing.expect(t, err2 == .None && got != nil && got.data == 7, "wait_receive should return message")
	if got != nil {free(got)}
}

@(test)
test_fifo_order :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	a := new(Msg); a.data = 1
	b := new(Msg); b.data = 2
	c := new(Msg); c.data = 3

	mbox.send(&mb, a)
	mbox.send(&mb, b)
	mbox.send(&mb, c)

	got1, _ := mbox.wait_receive(&mb, 0)
	got2, _ := mbox.wait_receive(&mb, 0)
	got3, _ := mbox.wait_receive(&mb, 0)

	testing.expect(t, got1 != nil && got1.data == 1, "first message should be 1")
	testing.expect(t, got2 != nil && got2.data == 2, "second message should be 2")
	testing.expect(t, got3 != nil && got3.data == 3, "third message should be 3")
	if got1 != nil {free(got1)}
	if got2 != nil {free(got2)}
	if got3 != nil {free(got3)}
}

@(test)
test_wait_receive_gets_message :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)

	// Allocate on the main thread. Worker sends it after a delay.
	// Receiver frees it. Allocation and free happen in the same thread (main).
	m := new(Msg)
	m.data = 99

	thread.run_with_poly_data2(&mb, m, proc(mb: ^mbox.Mailbox(Msg), m: ^Msg) {
		time.sleep(5 * time.Millisecond)
		mbox.send(mb, m)
	})

	got, err := mbox.wait_receive(&mb)
	testing.expect(t, err == .None, "wait_receive should not error")
	testing.expect(t, got != nil && got.data == 99, "wait_receive should get the sent message")
	if got != nil {
		free(got)
	}
}

// ----------------------------------------------------------------------------
// New mbox multi-waiter tests
// ----------------------------------------------------------------------------

// test_many_waiters_wake_on_close: 5 threads wait with no timeout.
// close() must wake all 5 with .Closed.
@(test)
test_many_waiters_wake_on_close :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	N :: 5
	done: sync.Sema
	ctxs: [N]_Multi_Waiter_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Multi_Waiter_Ctx{mb = &mb, done = &done}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Multi_Waiter_Ctx)(data)
			_, c.result = mbox.wait_receive(c.mb)
			sync.sema_post(c.done)
		})
	}

	time.sleep(20 * time.Millisecond)
	mbox.close(&mb)

	for _ in 0 ..< N {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	for i in 0 ..< N {
		testing.expect(t, ctxs[i].result == .Closed, "all waiters should get .Closed")
	}
}

// test_many_waiters_one_message: 5 threads wait. Send 1 message.
// Exactly 1 thread gets .None. Then close() wakes the remaining 4 with .Closed.
@(test)
test_many_waiters_one_message :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	N :: 5
	done: sync.Sema
	ctxs: [N]_Multi_Waiter_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Multi_Waiter_Ctx{mb = &mb, done = &done}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Multi_Waiter_Ctx)(data)
			_, c.result = mbox.wait_receive(c.mb)
			sync.sema_post(c.done)
		})
	}

	time.sleep(20 * time.Millisecond)
	msgs := make([]Msg, 1); defer delete(msgs)
	msgs[0].data = 42
	mbox.send(&mb, &msgs[0])

	sync.sema_wait(&done) // wait for the 1 thread that got the message
	mbox.close(&mb)       // wake the remaining 4

	for _ in 0 ..< 4 {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	none_count := 0
	closed_count := 0
	for i in 0 ..< N {
		#partial switch ctxs[i].result {
		case .None:
			none_count += 1
		case .Closed:
			closed_count += 1
		}
	}
	testing.expect(t, none_count == 1, "exactly 1 thread should get .None")
	testing.expect(t, closed_count == 4, "exactly 4 threads should get .Closed")
}

// test_many_waiters_one_interrupt: 5 threads wait. interrupt() wakes 1 with .Interrupted.
// Then close() wakes the remaining 4 with .Closed.
@(test)
test_many_waiters_one_interrupt :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	N :: 5
	done: sync.Sema
	ctxs: [N]_Multi_Waiter_Ctx
	threads: [N]^thread.Thread

	for i in 0 ..< N {
		ctxs[i] = _Multi_Waiter_Ctx{mb = &mb, done = &done}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], proc(data: rawptr) {
			c := (^_Multi_Waiter_Ctx)(data)
			_, c.result = mbox.wait_receive(c.mb)
			sync.sema_post(c.done)
		})
	}

	time.sleep(20 * time.Millisecond)
	mbox.interrupt(&mb)

	sync.sema_wait(&done) // wait for the 1 thread that got .Interrupted
	mbox.close(&mb)       // wake the remaining 4

	for _ in 0 ..< 4 {
		sync.sema_wait(&done)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	interrupted_count := 0
	closed_count := 0
	for i in 0 ..< N {
		#partial switch ctxs[i].result {
		case .Interrupted:
			interrupted_count += 1
		case .Closed:
			closed_count += 1
		}
	}
	testing.expect(t, interrupted_count == 1, "exactly 1 thread should get .Interrupted")
	testing.expect(t, closed_count == 4, "exactly 4 threads should get .Closed")
}

// test_heavy_racing: 10 senders × 100 messages + 10 receivers.
// All 1000 messages must be received. No crashes.
@(test)
test_heavy_racing :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	msgs := make([]Msg, 1_000)
	defer delete(msgs)

	received: int

	N_SENDERS :: 10
	N_RECEIVERS :: 10

	sender_ctxs: [N_SENDERS]_Sender_Ctx
	recv_ctxs: [N_RECEIVERS]_Receiver_Ctx
	sender_threads: [N_SENDERS]^thread.Thread
	recv_threads: [N_RECEIVERS]^thread.Thread

	for i in 0 ..< N_SENDERS {
		sender_ctxs[i] = _Sender_Ctx{mb = &mb, msgs = msgs[i * 100:(i + 1) * 100]}
		sender_threads[i] = thread.create_and_start_with_data(&sender_ctxs[i], proc(data: rawptr) {
			c := (^_Sender_Ctx)(data)
			for j in 0 ..< len(c.msgs) {
				mbox.send(c.mb, &c.msgs[j])
			}
		})
	}

	for i in 0 ..< N_RECEIVERS {
		recv_ctxs[i] = _Receiver_Ctx{mb = &mb, received = &received}
		recv_threads[i] = thread.create_and_start_with_data(&recv_ctxs[i], proc(data: rawptr) {
			c := (^_Receiver_Ctx)(data)
			for intrinsics.atomic_load(c.received) < 1000 {
				_, err := mbox.wait_receive(c.mb, 0)
				if err == .None {
					intrinsics.atomic_add(c.received, 1)
				}
			}
		})
	}

	for i in 0 ..< N_SENDERS {
		thread.join(sender_threads[i])
		thread.destroy(sender_threads[i])
	}
	for i in 0 ..< N_RECEIVERS {
		thread.join(recv_threads[i])
		thread.destroy(recv_threads[i])
	}

	testing.expect(t, received == 1_000, "all 1000 messages should be received")
}

// test_interrupted_then_closed: interrupt then close. wait_receive must return .Closed.
// close() clears the interrupted flag, so .Closed takes precedence.
@(test)
test_interrupted_then_closed :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	mbox.interrupt(&mb)
	mbox.close(&mb)
	_, err := mbox.wait_receive(&mb, 0)
	testing.expect(t, err == .Closed, "closed should take precedence over interrupted")
}
