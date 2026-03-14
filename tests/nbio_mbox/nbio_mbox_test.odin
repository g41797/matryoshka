// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

//+test
package nbio_mbox_tests

import nbio_mbox "../../nbio_mbox"
import try_mbox "../../try_mbox"
import examples "../../examples"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:testing"
import "core:time"

// test_nbio_mbox_invalid_loop: nil loop must return (nil, .Invalid_Loop).
@(test)
test_nbio_mbox_invalid_loop :: proc(t: ^testing.T) {
	m, err := nbio_mbox.init_nbio_mbox(examples.Msg, nil)
	testing.expect(t, m == nil, "init with nil loop should return nil mbox")
	testing.expect(t, err == .Invalid_Loop, "init with nil loop should return .Invalid_Loop")
}

// test_nbio_mbox_timeout_kind: create with .Timeout, send, tick, receive.
@(test)
test_nbio_mbox_timeout_kind :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(examples.Msg, loop, .Timeout)
	if !testing.expect(t, err == .None, "init .Timeout failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg: Maybe(^examples.Msg) = new(examples.Msg)
	msg.?.data = 11
	try_mbox.send(m, &msg)

	nbio.tick(10 * time.Millisecond)

	b1 := try_mbox.try_receive_batch(m)
	got := (^examples.Msg)(list.pop_front(&b1))
	testing.expect(t, got != nil && got.data == 11, "should receive the sent message")
	if got != nil {
		free(got)
	}
}

// test_nbio_mbox_udp_kind: create with .UDP, send, tick, receive.
@(test)
test_nbio_mbox_udp_kind :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	m, err := nbio_mbox.init_nbio_mbox(examples.Msg, loop, .UDP)
	if !testing.expect(t, err == .None, "init .UDP failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg: Maybe(^examples.Msg) = new(examples.Msg)
	msg.?.data = 22
	try_mbox.send(m, &msg)

	// tick lets the UDP recv callback fire and re-arm.
	nbio.tick(10 * time.Millisecond)

	b2 := try_mbox.try_receive_batch(m)
	got := (^examples.Msg)(list.pop_front(&b2))
	testing.expect(t, got != nil && got.data == 22, "should receive the sent message")
	if got != nil {
		free(got)
	}
}

// test_nbio_mbox_udp_default_kind: init with no kind arg uses .UDP (the default).
@(test)
test_nbio_mbox_udp_default_kind :: proc(t: ^testing.T) {
	if !testing.expect(t, nbio.acquire_thread_event_loop() == nil, "failed to acquire event loop") {
		return
	}
	defer nbio.release_thread_event_loop()
	loop := nbio.current_thread_event_loop()

	// No kind argument — should pick .UDP.
	m, err := nbio_mbox.init_nbio_mbox(examples.Msg, loop)
	if !testing.expect(t, err == .None, "init with default kind failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg: Maybe(^examples.Msg) = new(examples.Msg)
	msg.?.data = 33
	try_mbox.send(m, &msg)
	nbio.tick(10 * time.Millisecond)

	b3 := try_mbox.try_receive_batch(m)
	got := (^examples.Msg)(list.pop_front(&b3))
	testing.expect(t, got != nil && got.data == 33, "should receive the sent message")
	if got != nil {
		free(got)
	}
}
