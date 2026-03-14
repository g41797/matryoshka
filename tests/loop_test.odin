package tests

import "core:testing"
import "core:thread"
import "core:time"
import "core:nbio"
import list "core:container/intrusive/list"
import nbio_mbox "../nbio_mbox"
import try_mbox "../try_mbox"

// _Loop_Wake_Ctx holds state for the sender thread in test_loop_wake_on_send.
_Loop_Wake_Ctx :: struct {
	m:   ^try_mbox.Mbox(Msg),
	msg: ^Msg,
}

// _HF_Ctx holds state for the high-frequency sender thread in test_loop_high_freq_send.
_HF_Ctx :: struct {
	m:    ^try_mbox.Mbox(Msg),
	msgs: []Msg,
}

_HF_N :: 10_000

// ----------------------------------------------------------------------------
// nbio_mbox tests
// ----------------------------------------------------------------------------

// test_loop_basic: send 3 messages, check length, drain in FIFO order.
@(test)
test_loop_basic :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	a := new(Msg); a.data = 1
	b := new(Msg); b.data = 2
	c := new(Msg); c.data = 3
	try_mbox.send(m, a)
	try_mbox.send(m, b)
	try_mbox.send(m, c)

	testing.expect(t, try_mbox.length(m) == 3, "length should be 3 after 3 sends")

	msg1, ok1 := try_mbox.try_receive(m)
	msg2, ok2 := try_mbox.try_receive(m)
	msg3, ok3 := try_mbox.try_receive(m)
	msg4, ok4 := try_mbox.try_receive(m)

	testing.expect(t, ok1 && msg1 != nil && msg1.data == 1, "first message should be 1")
	testing.expect(t, ok2 && msg2 != nil && msg2.data == 2, "second message should be 2")
	testing.expect(t, ok3 && msg3 != nil && msg3.data == 3, "third message should be 3")
	testing.expect(t, !ok4 && msg4 == nil, "fourth receive should return (nil, false)")
	if msg1 != nil {free(msg1)}
	if msg2 != nil {free(msg2)}
	if msg3 != nil {free(msg3)}
}

// test_loop_close_and_drain: send 2 messages, close, check remaining count and that send returns false.
@(test)
test_loop_close_and_drain :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	a := new(Msg); a.data = 10
	b := new(Msg); b.data = 20
	try_mbox.send(m, a)
	try_mbox.send(m, b)

	remaining, was_open := try_mbox.close(m)
	testing.expect(t, was_open, "first close should return was_open=true")

	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		free((^Msg)(node))
		count += 1
	}
	testing.expect(t, count == 2, "close should return 2 remaining messages")

	extra := new(Msg); extra.data = 99; defer free(extra)
	ok := try_mbox.send(m, extra)
	testing.expect(t, !ok, "send after close should return false")
}

// test_loop_wake_on_send: thread sends a message; main loop wakes via nbio.tick.
@(test)
test_loop_wake_on_send :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg := new(Msg); msg.data = 77
	ctx := _Loop_Wake_Ctx{m = m, msg = msg}
	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_Loop_Wake_Ctx)(data)
		time.sleep(10 * time.Millisecond) // Give loop time to enter tick()
		try_mbox.send(c.m, c.msg)
	})

	got: ^Msg
	for _ in 0 ..< 100 {
		tick_err := nbio.tick(200 * time.Millisecond)
		if tick_err != nil {
			break
		}
		received, ok := try_mbox.try_receive(m)
		if ok {
			got = received
			break
		}
	}

	if got == nil {
		got, _ = try_mbox.try_receive(m)
	}

	thread.join(th)
	thread.destroy(th)

	testing.expect(t, got != nil && got.data == 77, "should receive the message sent by thread")
	if got != nil {free(got)}
}

// test_loop_invalid_loop: init_nbio_mbox with nil loop returns (nil, .Invalid_Loop).
@(test)
test_loop_invalid_loop :: proc(t: ^testing.T) {
	m, err := nbio_mbox.init_nbio_mbox(Msg, nil)
	testing.expect(t, m == nil, "init_nbio_mbox(nil) should return nil mbox")
	testing.expect(t, err == .Invalid_Loop, "init_nbio_mbox(nil) should return .Invalid_Loop")
}

// test_loop_high_freq_send: worker sends 10,000 messages in a tight loop; main drains via tick.
// Verifies the wake_pending throttle prevents nbio queue overflow and all messages are received.
@(test)
test_loop_high_freq_send :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msgs := make([]Msg, _HF_N)
	defer delete(msgs)
	for i in 0 ..< _HF_N {
		msgs[i] = Msg{data = i}
	}

	ctx := _HF_Ctx{m = m, msgs = msgs}
	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_HF_Ctx)(data)
		for i in 0 ..< len(c.msgs) {
			try_mbox.send(c.m, &c.msgs[i])
		}
	})

	received := 0
	for received < _HF_N {
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

	thread.join(th)
	thread.destroy(th)

	// Drain any remaining messages (stall or residual).
	for {
		_, ok := try_mbox.try_receive(m)
		if !ok {break}
		received += 1
	}

	testing.expect(t, received == _HF_N, "should receive all 10,000 messages")
}

// test_loop_double_close: close twice. First returns was_open=true, second false.
@(test)
test_loop_double_close :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	if !testing.expect(t, err == .None, "init_nbio_mbox failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	_, was_open1 := try_mbox.close(m)
	_, was_open2 := try_mbox.close(m)

	testing.expect(t, was_open1, "first close should return was_open=true")
	testing.expect(t, !was_open2, "second close should return was_open=false")
}
