// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package nbio_mbox

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:testing"
import "core:time"
import try_mbox "../try_mbox"

// -vet: keep list import used.
@(private) _TL :: list.Node
@(private) _TI :: intrinsics.type_has_field

// _Test_Msg is the message type used in unit tests.
_Test_Msg :: struct {
	node: list.Node,
	data: int,
}

// test_nbio_mbox_invalid_loop: nil loop must return (nil, .Invalid_Loop).
@(test)
test_nbio_mbox_invalid_loop :: proc(t: ^testing.T) {
	m, err := init_nbio_mbox(_Test_Msg, nil)
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

	m, err := init_nbio_mbox(_Test_Msg, loop, .Timeout)
	if !testing.expect(t, err == .None, "init .Timeout failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg := new(_Test_Msg)
	msg.data = 11
	try_mbox.send(m, msg)

	nbio.tick(10 * time.Millisecond)

	got, ok := try_mbox.try_receive(m)
	testing.expect(t, ok && got != nil && got.data == 11, "should receive the sent message")
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

	m, err := init_nbio_mbox(_Test_Msg, loop, .UDP)
	if !testing.expect(t, err == .None, "init .UDP failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg := new(_Test_Msg)
	msg.data = 22
	try_mbox.send(m, msg)

	// tick lets the UDP recv callback fire and re-arm.
	nbio.tick(10 * time.Millisecond)

	got, ok := try_mbox.try_receive(m)
	testing.expect(t, ok && got != nil && got.data == 22, "should receive the sent message")
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
	m, err := init_nbio_mbox(_Test_Msg, loop)
	if !testing.expect(t, err == .None, "init with default kind failed") {
		return
	}
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	msg := new(_Test_Msg)
	msg.data = 33
	try_mbox.send(m, msg)
	nbio.tick(10 * time.Millisecond)

	got, ok := try_mbox.try_receive(m)
	testing.expect(t, ok && got != nil && got.data == 33, "should receive the sent message")
	if got != nil {
		free(got)
	}
}
