package tests

import "core:testing"
import "core:thread"
import "core:time"
import "core:nbio"
import list "core:container/intrusive/list"
import mbox ".."

// _Loop_Wake_Ctx holds state for the sender thread in test_loop_wake_on_send.
_Loop_Wake_Ctx :: struct {
	lm:  ^mbox.Loop_Mailbox(Msg),
	msg: ^Msg,
}

// ----------------------------------------------------------------------------
// Loop_Mailbox tests
// ----------------------------------------------------------------------------

// test_loop_basic: send 3 messages, check stats, drain in FIFO order.
@(test)
test_loop_basic :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	lm: mbox.Loop_Mailbox(Msg)
	mbox.init_loop_mailbox(&lm, loop)

	a := Msg{data = 1}
	b := Msg{data = 2}
	c := Msg{data = 3}
	mbox.send_to_loop(&lm, &a)
	mbox.send_to_loop(&lm, &b)
	mbox.send_to_loop(&lm, &c)

	testing.expect(t, mbox.stats(&lm) == 3, "stats should be 3 after 3 sends")

	msg1, ok1 := mbox.try_receive_loop(&lm)
	msg2, ok2 := mbox.try_receive_loop(&lm)
	msg3, ok3 := mbox.try_receive_loop(&lm)
	msg4, ok4 := mbox.try_receive_loop(&lm)

	testing.expect(t, ok1 && msg1 != nil && msg1.data == 1, "first message should be 1")
	testing.expect(t, ok2 && msg2 != nil && msg2.data == 2, "second message should be 2")
	testing.expect(t, ok3 && msg3 != nil && msg3.data == 3, "third message should be 3")
	testing.expect(t, !ok4 && msg4 == nil, "fourth receive should return (nil, false)")
}

// test_loop_close_and_drain: send 2 messages, close, check remaining count and that send returns false.
@(test)
test_loop_close_and_drain :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	lm: mbox.Loop_Mailbox(Msg)
	mbox.init_loop_mailbox(&lm, loop)

	a := Msg{data = 10}
	b := Msg{data = 20}
	mbox.send_to_loop(&lm, &a)
	mbox.send_to_loop(&lm, &b)

	remaining, was_open := mbox.close_loop(&lm)
	testing.expect(t, was_open, "first close should return was_open=true")

	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		count += 1
	}
	testing.expect(t, count == 2, "close_loop should return 2 remaining messages")

	ok := mbox.send_to_loop(&lm, &a)
	testing.expect(t, !ok, "send_to_loop after close should return false")
}

// test_loop_wake_on_send: thread sends a message; main loop wakes via nbio.tick.
@(test)
test_loop_wake_on_send :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	lm: mbox.Loop_Mailbox(Msg)
	mbox.init_loop_mailbox(&lm, loop)

	m := Msg{data = 77}
	ctx := _Loop_Wake_Ctx{lm = &lm, msg = &m}
	th := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		c := (^_Loop_Wake_Ctx)(data)
		time.sleep(10 * time.Millisecond) // Give loop time to enter tick()
		mbox.send_to_loop(c.lm, c.msg)
	})

	got: ^Msg
	for _ in 0 ..< 100 {
		tick_err := nbio.tick(200 * time.Millisecond)
		if tick_err != nil {
			break
		}
		msg, ok := mbox.try_receive_loop(&lm)
		if ok {
			got = msg
			break
		}
	}

	if got == nil {
		got, _ = mbox.try_receive_loop(&lm)
	}

	thread.join(th)
	thread.destroy(th)

	testing.expect(t, got != nil && got.data == 77, "should receive the message sent by thread")
}

// test_loop_double_close: close_loop twice. First returns was_open=true, second false.
@(test)
test_loop_double_close :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	lm: mbox.Loop_Mailbox(Msg)
	mbox.init_loop_mailbox(&lm, loop)

	_, was_open1 := mbox.close_loop(&lm)
	_, was_open2 := mbox.close_loop(&lm)

	testing.expect(t, was_open1, "first close_loop should return was_open=true")
	testing.expect(t, !was_open2, "second close_loop should return was_open=false")
}
