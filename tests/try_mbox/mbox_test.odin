// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

//+test
package try_mbox_tests

import try_mbox "../../try_mbox"
import examples "../../examples"
import wakeup "../../wakeup"
import list "core:container/intrusive/list"
import "core:testing"

// _WC is a counter for waker callback tests.
_WC :: struct {
	wake_count:   int,
	close_called: bool,
}

@(private)
_wc_wake :: proc(ctx: rawptr) {
	c := (^_WC)(ctx)
	c.wake_count += 1
}

@(private)
_wc_close :: proc(ctx: rawptr) {
	c := (^_WC)(ctx)
	c.close_called = true
}

@(test)
test_init_destroy :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	testing.expect(t, m != nil, "init should return non-nil")
	_, _ = try_mbox.close(m)
	try_mbox.destroy(m)
}

@(test)
test_send_try_receive_basic :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer {_, _ = try_mbox.close(m); try_mbox.destroy(m)}
	msg_ptr := new(examples.Msg); msg_ptr.data = 42
	msg: Maybe(^examples.Msg) = msg_ptr
	ok := try_mbox.send(m, &msg)
	testing.expect(t, ok, "send should return true")
	batch := try_mbox.try_receive_batch(m)
	got := (^examples.Msg)(list.pop_front(&batch))
	testing.expect(t, got != nil, "try_receive_batch should return a message")
	testing.expect(t, got != nil && got.data == 42, "received message should have data == 42")
	if got != nil {free(got)}
}

@(test)
test_try_receive_empty :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer {_, _ = try_mbox.close(m); try_mbox.destroy(m)}
	batch := try_mbox.try_receive_batch(m)
	got := (^examples.Msg)(list.pop_front(&batch))
	testing.expect(t, got == nil, "try_receive_batch on empty should return nil")
}

@(test)
test_send_closed :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer try_mbox.destroy(m)
	_, _ = try_mbox.close(m)
	// send will fail (closed), so msg_ptr remains valid — defer free is safe
	msg_ptr := new(examples.Msg); msg_ptr.data = 1; defer free(msg_ptr)
	msg: Maybe(^examples.Msg) = msg_ptr
	ok := try_mbox.send(m, &msg)
	testing.expect(t, !ok, "send after close should return false")
}

@(test)
test_close_returns_remaining :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer try_mbox.destroy(m)
	a := new(examples.Msg); a.data = 1
	b := new(examples.Msg); b.data = 2
	c := new(examples.Msg); c.data = 3
	a_opt: Maybe(^examples.Msg) = a; try_mbox.send(m, &a_opt)
	b_opt: Maybe(^examples.Msg) = b; try_mbox.send(m, &b_opt)
	c_opt: Maybe(^examples.Msg) = c; try_mbox.send(m, &c_opt)
	remaining, was_open := try_mbox.close(m)
	testing.expect(t, was_open, "close should return was_open == true")
	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		free((^examples.Msg)(node))
		count += 1
	}
	testing.expect(t, count == 3, "close should drain 3 remaining messages")
}

@(test)
test_close_idempotent :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer try_mbox.destroy(m) // m.closed == true after first close below
	_, first := try_mbox.close(m)
	_, second := try_mbox.close(m)
	testing.expect(t, first, "first close should return true")
	testing.expect(t, !second, "second close should return false")
}

@(test)
test_length :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer {_, _ = try_mbox.close(m); try_mbox.destroy(m)}
	testing.expect(t, try_mbox.length(m) == 0, "length should be 0 initially")
	a := new(examples.Msg); a.data = 1
	b := new(examples.Msg); b.data = 2
	a_opt: Maybe(^examples.Msg) = a; try_mbox.send(m, &a_opt)
	b_opt: Maybe(^examples.Msg) = b; try_mbox.send(m, &b_opt)
	testing.expect(t, try_mbox.length(m) == 2, "length should be 2 after 2 sends")
	batch := try_mbox.try_receive_batch(m)
	for node := list.pop_front(&batch); node != nil; node = list.pop_front(&batch) {
		free((^examples.Msg)(node))
	}
	testing.expect(t, try_mbox.length(m) == 0, "length should be 0 after try_receive_batch")
}

@(test)
test_waker_called_on_send :: proc(t: ^testing.T) {
	wc: _WC
	waker := wakeup.WakeUper{ctx = rawptr(&wc), wake = _wc_wake}
	m := try_mbox.init(examples.Msg, waker)
	defer {_, _ = try_mbox.close(m); try_mbox.destroy(m)}
	a_ptr := new(examples.Msg); a_ptr.data = 1
	b_ptr := new(examples.Msg); b_ptr.data = 2
	c_ptr := new(examples.Msg); c_ptr.data = 3
	a: Maybe(^examples.Msg) = a_ptr; try_mbox.send(m, &a)
	b: Maybe(^examples.Msg) = b_ptr; try_mbox.send(m, &b)
	c: Maybe(^examples.Msg) = c_ptr; try_mbox.send(m, &c)
	// wake should be called once per send; 3 sends → count == 3
	testing.expect(t, wc.wake_count == 3, "wake should be called once per send; 3 sends → count == 3")
	drain := try_mbox.try_receive_batch(m)
	for node := list.pop_front(&drain); node != nil; node = list.pop_front(&drain) {
		free((^examples.Msg)(node))
	}
}

@(test)
test_waker_close_on_close :: proc(t: ^testing.T) {
	wc: _WC
	waker := wakeup.WakeUper{ctx = rawptr(&wc), close = _wc_close}
	m := try_mbox.init(examples.Msg, waker)
	defer try_mbox.destroy(m) // m.closed == true after close() below
	_, _ = try_mbox.close(m)
	testing.expect(t, wc.close_called, "waker.close should be called on mailbox close")
}

@(test)
test_no_waker :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg) // zero WakeUper
	defer {_, _ = try_mbox.close(m); try_mbox.destroy(m)}
	msg_ptr := new(examples.Msg); msg_ptr.data = 99
	msg: Maybe(^examples.Msg) = msg_ptr
	ok := try_mbox.send(m, &msg)
	testing.expect(t, ok, "send without waker should return true")
	batch := try_mbox.try_receive_batch(m)
	got := (^examples.Msg)(list.pop_front(&batch))
	testing.expect(t, got != nil && got.data == 99, "try_receive_batch without waker should work")
	if got != nil {free(got)}
}

@(test)
test_try_receive_batch_basic :: proc(t: ^testing.T) {
	m := try_mbox.init(examples.Msg)
	defer {_, _ = try_mbox.close(m); try_mbox.destroy(m)}
	a := new(examples.Msg); a.data = 1
	b := new(examples.Msg); b.data = 2
	c := new(examples.Msg); c.data = 3
	a_opt: Maybe(^examples.Msg) = a; try_mbox.send(m, &a_opt)
	b_opt: Maybe(^examples.Msg) = b; try_mbox.send(m, &b_opt)
	c_opt: Maybe(^examples.Msg) = c; try_mbox.send(m, &c_opt)
	result := try_mbox.try_receive_batch(m)
	count := 0
	for node := list.pop_front(&result); node != nil; node = list.pop_front(&result) {
		free((^examples.Msg)(node))
		count += 1
	}
	testing.expect(t, count == 3, "try_receive_batch should return all 3 messages")
	testing.expect(t, try_mbox.length(m) == 0, "queue should be empty after try_receive_batch")
}
