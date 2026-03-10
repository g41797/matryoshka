package tests

import "core:testing"
import "core:thread"
import "core:time"
import list "core:container/intrusive/list"
import examples "../examples"
import mbox ".."

// --- example tests ---

@(test)
test_negotiation :: proc(t: ^testing.T) {
	testing.expect(t, examples.negotiation_example(), "negotiation_example failed")
}

@(test)
test_stress :: proc(t: ^testing.T) {
	testing.expect(t, examples.stress_example(), "stress_example failed")
}

@(test)
test_endless_game :: proc(t: ^testing.T) {
	testing.expect(t, examples.endless_game_example(), "endless_game_example failed")
}

@(test)
test_example_interrupt :: proc(t: ^testing.T) {
	testing.expect(t, examples.interrupt_example(), "interrupt_example failed")
}

@(test)
test_example_close :: proc(t: ^testing.T) {
	testing.expect(t, examples.close_example(), "close_example failed")
}

@(test)
test_example_lifecycle :: proc(t: ^testing.T) {
	testing.expect(t, examples.lifecycle_example(), "lifecycle_example failed")
}

// --- Mailbox edge-case tests ---

// Msg is the local test message type.
Msg :: struct {
	node: list.Node,
	data: int,
}

@(test)
test_send_and_receive :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	m := Msg{data = 42}

	ok := mbox.send(&mb, &m)
	testing.expect(t, ok, "send should return true")

	got, err := mbox.wait_receive(&mb, 0)
	testing.expect(t, err == .None, "wait_receive should return .None")
	testing.expect(t, got != nil && got.data == 42, "wait_receive wrong data")
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
	m := Msg{data = 1}

	_, _ = mbox.close(&mb)

	ok := mbox.send(&mb, &m)
	testing.expect(t, !ok, "send to closed mailbox should return false")
}

@(test)
test_close_wakes_waiter :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	result: mbox.Mailbox_Error

	// Start a waiter thread.
	thread.run_with_poly_data2(&mb, &result, proc(mb: ^mbox.Mailbox(Msg), result: ^mbox.Mailbox_Error) {
		_, err := mbox.wait_receive(mb)
		result^ = err
	})

	time.sleep(10 * time.Millisecond)
	_, _ = mbox.close(&mb)
	time.sleep(20 * time.Millisecond)

	testing.expect(t, result == .Closed, "waiter should get .Closed after close()")
}

@(test)
test_close_returns_remaining :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	a := Msg{data = 10}
	b := Msg{data = 20}

	mbox.send(&mb, &a)
	mbox.send(&mb, &b)

	remaining, was_open := mbox.close(&mb)
	testing.expect(t, was_open, "first close should return was_open=true")

	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
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

	// Start a waiter thread.
	thread.run_with_poly_data2(&mb, &result, proc(mb: ^mbox.Mailbox(Msg), result: ^mbox.Mailbox_Error) {
		_, err := mbox.wait_receive(mb)
		result^ = err
	})

	time.sleep(10 * time.Millisecond)
	ok := mbox.interrupt(&mb)
	testing.expect(t, ok, "interrupt should return true on first call")
	time.sleep(20 * time.Millisecond)
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
	m := Msg{data = 7}

	_, _ = mbox.close(&mb)
	mb = {} // reinitialize — safe after no waiters

	ok := mbox.send(&mb, &m)
	testing.expect(t, ok, "send after reinitialization should succeed")

	got, err2 := mbox.wait_receive(&mb, 0)
	testing.expect(t, err2 == .None && got != nil && got.data == 7, "wait_receive should return message")
}

@(test)
test_fifo_order :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	a := Msg{data = 1}
	b := Msg{data = 2}
	c := Msg{data = 3}

	mbox.send(&mb, &a)
	mbox.send(&mb, &b)
	mbox.send(&mb, &c)

	got1, _ := mbox.wait_receive(&mb, 0)
	got2, _ := mbox.wait_receive(&mb, 0)
	got3, _ := mbox.wait_receive(&mb, 0)

	testing.expect(t, got1 != nil && got1.data == 1, "first message should be 1")
	testing.expect(t, got2 != nil && got2.data == 2, "second message should be 2")
	testing.expect(t, got3 != nil && got3.data == 3, "third message should be 3")
}

@(test)
test_wait_receive_gets_message :: proc(t: ^testing.T) {
	mb: mbox.Mailbox(Msg)
	m := Msg{data = 99}

	// Send from a separate thread after a short delay.
	thread.run_with_poly_data2(&mb, &m, proc(mb: ^mbox.Mailbox(Msg), m: ^Msg) {
		time.sleep(5 * time.Millisecond)
		mbox.send(mb, m)
	})

	got, err := mbox.wait_receive(&mb)
	testing.expect(t, err == .None, "wait_receive should not error")
	testing.expect(t, got != nil && got.data == 99, "wait_receive should get the sent message")
}
