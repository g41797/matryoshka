//+test
package nbio_mbox_tests

import nbio_mbox "../../nbio_mbox"
import loop_mbox "../../loop_mbox"
import examples "../../examples"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:testing"
import "core:thread"
import "core:time"

// _Loop_Wake_Ctx holds state for the sender thread in test_loop_wake_on_send.
_Loop_Wake_Ctx :: struct {
	m:   ^loop_mbox.Mbox(examples.Itm),
	msg: ^examples.Itm,
}

// _HF_Ctx holds state for the high-frequency sender thread in test_loop_high_freq_send.
_HF_Ctx :: struct {
	m:    ^loop_mbox.Mbox(examples.Itm),
	msgs: []examples.Itm,
}

_HF_N :: 10_000

// ----------------------------------------------------------------------------
// nbio_mbox tests
// ----------------------------------------------------------------------------

// _test_loop_basic: send 3 messages, check length, drain in FIFO order.
@(private)
_test_loop_basic :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
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

	a_ptr := new(examples.Itm); a_ptr.data = 1
	b_ptr := new(examples.Itm); b_ptr.data = 2
	c_ptr := new(examples.Itm); c_ptr.data = 3
	a_opt: Maybe(^examples.Itm) = a_ptr; loop_mbox.send(m, &a_opt)
	b_opt: Maybe(^examples.Itm) = b_ptr; loop_mbox.send(m, &b_opt)
	c_opt: Maybe(^examples.Itm) = c_ptr; loop_mbox.send(m, &c_opt)

	testing.expect(t, loop_mbox.length(m) == 3, "length should be 3 after 3 sends")

	batch := loop_mbox.try_receive_batch(m)
	msg1 := (^examples.Itm)(list.pop_front(&batch))
	msg2 := (^examples.Itm)(list.pop_front(&batch))
	msg3 := (^examples.Itm)(list.pop_front(&batch))
	msg4 := (^examples.Itm)(list.pop_front(&batch))

	testing.expect(t, msg1 != nil && msg1.data == 1, "first message should be 1")
	testing.expect(t, msg2 != nil && msg2.data == 2, "second message should be 2")
	testing.expect(t, msg3 != nil && msg3.data == 3, "third message should be 3")
	testing.expect(t, msg4 == nil, "fourth receive should return nil")
	if msg1 != nil {free(msg1)}
	if msg2 != nil {free(msg2)}
	if msg3 != nil {free(msg3)}
}

@(test)
test_loop_basic :: proc(t: ^testing.T) {
	_test_loop_basic(t, .Timeout)
	_test_loop_basic(t, .UDP)
}

// _test_loop_close_and_drain: send 2 messages, close, check remaining count and that send returns false.
@(private)
_test_loop_close_and_drain :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
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

	a := new(examples.Itm); a.data = 10
	b := new(examples.Itm); b.data = 20
	a_opt: Maybe(^examples.Itm) = a; loop_mbox.send(m, &a_opt)
	b_opt: Maybe(^examples.Itm) = b; loop_mbox.send(m, &b_opt)

	remaining, was_open := loop_mbox.close(m)
	testing.expect(t, was_open, "first close should return was_open=true")

	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		free((^examples.Itm)(node))
		count += 1
	}
	testing.expect(t, count == 2, "close should return 2 remaining messages")

	extra := new(examples.Itm); extra.data = 99; defer free(extra)
	extra_opt: Maybe(^examples.Itm) = extra
	ok := loop_mbox.send(m, &extra_opt)
	testing.expect(t, !ok, "send after close should return false")
}

@(test)
test_loop_close_and_drain :: proc(t: ^testing.T) {
	_test_loop_close_and_drain(t, .Timeout)
	_test_loop_close_and_drain(t, .UDP)
}

// _test_loop_wake_on_send: thread sends a message; main loop wakes via nbio.tick.
@(private)
_test_loop_wake_on_send :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
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

	msg := new(examples.Itm); msg.data = 77
	ctx := _Loop_Wake_Ctx {
		m   = m,
		msg = msg,
	}
	th := thread.create_and_start_with_data(
	&ctx,
	proc(data: rawptr) {
		c := (^_Loop_Wake_Ctx)(data)
		time.sleep(10 * time.Millisecond) // Give loop time to enter tick()
		msg_opt: Maybe(^examples.Itm) = c.msg
		loop_mbox.send(c.m, &msg_opt)
	},
	)

	got: ^examples.Itm
	for _ in 0 ..< 100 {
		tick_err := nbio.tick(200 * time.Millisecond)
		if tick_err != nil {
			break
		}
		wb := loop_mbox.try_receive_batch(m)
		node := list.pop_front(&wb)
		if node != nil {
			got = (^examples.Itm)(node)
			break
		}
	}

	// Join before the final drain: on Windows .Timeout busy-polls (no keepalive),
	// so the tick loop may exhaust before the sender wakes. Joining ensures the
	// sender has sent before we do the last try_receive_batch.
	thread.join(th)
	thread.destroy(th)

	if got == nil {
		fb := loop_mbox.try_receive_batch(m)
		node := list.pop_front(&fb)
		if node != nil {got = (^examples.Itm)(node)}
	}

	testing.expect(t, got != nil && got.data == 77, "should receive the message sent by thread")
	if got != nil {free(got)}
}

@(test)
test_loop_wake_on_send :: proc(t: ^testing.T) {
	_test_loop_wake_on_send(t, .Timeout)
	_test_loop_wake_on_send(t, .UDP)
}

// test_loop_invalid_loop: init_nbio_mbox with nil loop returns (nil, .Invalid_Loop).
@(test)
test_loop_invalid_loop :: proc(t: ^testing.T) {
	m, err := nbio_mbox.init_nbio_mbox(examples.Itm, nil)
	testing.expect(t, m == nil, "init_nbio_mbox(nil) should return nil mbox")
	testing.expect(t, err == .Invalid_Loop, "init_nbio_mbox(nil) should return .Invalid_Loop")
}

// _test_loop_high_freq_send: worker sends 10,000 messages in a tight loop; main drains via tick.
// Verifies the wake_pending throttle prevents nbio queue overflow and all messages are received.
@(private)
_test_loop_high_freq_send :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
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

	msgs := make([]examples.Itm, _HF_N)
	defer delete(msgs)
	for i in 0 ..< _HF_N {
		msgs[i] = examples.Itm {
			data = i,
		}
	}

	ctx := _HF_Ctx {
		m    = m,
		msgs = msgs,
	}
	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_HF_Ctx)(data)
		for i in 0 ..< len(c.msgs) {
			msg_opt: Maybe(^examples.Itm) = &c.msgs[i]
			loop_mbox.send(c.m, &msg_opt)
		}
	})

	received := 0
	for received < _HF_N {
		tick_err := nbio.tick(100 * time.Millisecond)
		if tick_err != nil {
			break
		}
		hb := loop_mbox.try_receive_batch(m)
		for node := list.pop_front(&hb); node != nil; node = list.pop_front(&hb) {
			received += 1
		}
	}

	thread.join(th)
	thread.destroy(th)

	// Drain any remaining messages (stall or residual).
	rb := loop_mbox.try_receive_batch(m)
	for node := list.pop_front(&rb); node != nil; node = list.pop_front(&rb) {
		received += 1
	}

	testing.expect(t, received == _HF_N, "should receive all 10,000 messages")
}

@(test)
test_loop_high_freq_send :: proc(t: ^testing.T) {
	_test_loop_high_freq_send(t, .Timeout)
	_test_loop_high_freq_send(t, .UDP)
}

// _test_loop_double_close: close twice. First returns was_open=true, second false.
@(private)
_test_loop_double_close :: proc(t: ^testing.T, kind: nbio_mbox.Nbio_Wakeuper_Kind) {
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

	_, was_open1 := loop_mbox.close(m)
	_, was_open2 := loop_mbox.close(m)

	testing.expect(t, was_open1, "first close should return was_open=true")
	testing.expect(t, !was_open2, "second close should return was_open=false")
}

@(test)
test_loop_double_close :: proc(t: ^testing.T) {
	_test_loop_double_close(t, .Timeout)
	_test_loop_double_close(t, .UDP)
}
