// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package nbio_mbox

import loop_mbox "../loop_mbox"
import wakeup "../wakeup"
import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

// -vet workarounds: some import usages are not detected in all contexts.
@(private)
_NBioList :: list.Node
@(private)
_NBioDuration :: time.Duration
@(private)
_NBioWaker :: wakeup.WakeUper

// Nbio_Wakeuper_Kind selects the mechanism used to wake the nbio event loop.
//   .Timeout — zero-duration nbio timeout (original approach; 128-slot cross-thread queue)
//   .UDP     — loopback UDP socket; sender writes 1 byte, nbio wakes on receipt (default)
Nbio_Wakeuper_Kind :: enum {
	Timeout,
	UDP,
}

// Nbio_Mailbox_Error is the error returned by init_nbio_mbox.
Nbio_Mailbox_Error :: enum {
	None,
	Invalid_Loop,
	Keepalive_Failed,
	Socket_Failed, // UDP socket or bind error
}

// ---------------------------------------------------------------------------
// Timeout wakeuper (_NBio_State)
// ---------------------------------------------------------------------------

// _NBio_State holds the nbio event loop and keepalive timer for one nbio_mbox instance.
@(private)
_NBio_State :: struct {
	loop:      ^nbio.Event_Loop,
	keepalive: ^nbio.Operation,
	allocator: mem.Allocator,
}

// _noop is the required no-op callback for nbio operations (used by keepalive timer).
@(private)
_noop :: proc(_: ^nbio.Operation) {}

// _nbio_wake wakes the nbio event loop via nbio.wake_up.
// Uses QueueUserAPC on Windows — no cross-thread operation allocation, no 128-slot queue.
// Safe to call from any thread.
@(private)
_nbio_wake :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_NBio_State)(ctx)
	nbio.wake_up(state.loop)
}

// _nbio_close removes the keepalive timer and frees state.
// Must be called from the event-loop thread — nbio.remove panics cross-thread.
@(private)
_nbio_close :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_NBio_State)(ctx)
	if state.keepalive != nil {
		nbio.remove(state.keepalive)
		state.keepalive = nil
	}
	free(state, state.allocator)
}

@(private)
_init_timeout_wakeup :: proc(
	loop: ^nbio.Event_Loop,
	allocator: mem.Allocator,
) -> (
	waker: wakeup.WakeUper,
	ok: bool,
) {
	state := new(_NBio_State, allocator)
	if state == nil {
		return {}, false
	}
	state.loop = loop
	state.allocator = allocator
	state.keepalive = nbio.timeout(time.Hour * 24, _noop, loop)
	if state.keepalive == nil {
		free(state, allocator)
		return {}, false
	}
	// Flush pending kqueue changes on macOS.
	nbio.tick(0)
	return wakeup.WakeUper{ctx = rawptr(state), wake = _nbio_wake, close = _nbio_close}, true
}

// ---------------------------------------------------------------------------
// UDP wakeuper (_UDP_State)
// ---------------------------------------------------------------------------

// _UDP_State holds the loopback UDP sockets used to wake the nbio event loop.
// recv_sock is registered with nbio; send_sock is used from sender threads.
@(private)
_UDP_State :: struct {
	recv_sock: net.UDP_Socket,
	send_sock: net.UDP_Socket,
	endpoint:  net.Endpoint,
	loop:      ^nbio.Event_Loop,
	allocator: mem.Allocator,
	recv_buf:  [1]byte,
	recv_op:   ^nbio.Operation,
	closed:    bool, // atomic
}

// _udp_wake sends one byte to recv_sock to wake the event loop.
// Safe to call from any thread.
@(private)
_udp_wake :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_UDP_State)(ctx)
	buf := [1]byte{0}
	net.send_udp(state.send_sock, buf[:], state.endpoint)
}

// _udp_recv_cb re-arms the recv operation so the next wake works.
// Runs in the event-loop thread.
@(private)
_udp_recv_cb :: proc(op: ^nbio.Operation, state: ^_UDP_State) {
	if intrinsics.atomic_load(&state.closed) {
		return
	}
	bufs := [1][]byte{state.recv_buf[:]}
	state.recv_op = nbio.recv_poly(state.recv_sock, bufs[:], state, _udp_recv_cb, l = state.loop)
}

// _udp_close cancels the pending recv, closes both sockets, and frees state.
// Must be called from the event-loop thread — nbio.remove panics cross-thread.
//
// nbio.tick(0) after remove drains any pending IOCP cancellation completion on
// Windows before the sockets and state are freed. On Linux/macOS remove is truly
// silent (callback never fires), so tick(0) is a no-op there.
@(private)
_udp_close :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_UDP_State)(ctx)
	intrinsics.atomic_store(&state.closed, true)
	if state.recv_op != nil {
		nbio.remove(state.recv_op)
		state.recv_op = nil
	}
	nbio.tick(0) // drain IOCP cancellation completion before freeing buffers
	net.close(state.recv_sock)
	net.close(state.send_sock)
	free(state, state.allocator)
}

@(private)
_init_udp_wakeup :: proc(
	loop: ^nbio.Event_Loop,
	allocator: mem.Allocator,
) -> (
	waker: wakeup.WakeUper,
	ok: bool,
) {
	state := new(_UDP_State, allocator)
	if state == nil {
		return {}, false
	}
	state.loop = loop
	state.allocator = allocator

	// 1. Bound recv socket on ephemeral loopback port.
	recv_sock, err1 := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if err1 != nil {
		free(state, allocator)
		return {}, false
	}
	state.recv_sock = recv_sock

	// 2. Non-blocking recv socket.
	net.set_blocking(state.recv_sock, false)

	// 3. Store ephemeral endpoint (address:port).
	endpoint, err2 := net.bound_endpoint(state.recv_sock)
	if err2 != nil {
		net.close(state.recv_sock)
		free(state, allocator)
		return {}, false
	}
	state.endpoint = endpoint

	// 4. Register recv socket with the event loop.
	if assoc_err := nbio.associate_socket(state.recv_sock, loop); assoc_err != nil {
		net.close(state.recv_sock)
		free(state, allocator)
		return {}, false
	}

	// 5. Unbound send socket (used by sender threads).
	send_sock, err3 := net.make_unbound_udp_socket(.IP4)
	if err3 != nil {
		net.close(state.recv_sock)
		free(state, allocator)
		return {}, false
	}
	state.send_sock = send_sock
	net.set_blocking(state.send_sock, false)

	// 6. Arm the recv loop.
	bufs := [1][]byte{state.recv_buf[:]}
	state.recv_op = nbio.recv_poly(state.recv_sock, bufs[:], state, _udp_recv_cb, l = loop)

	return wakeup.WakeUper{ctx = rawptr(state), wake = _udp_wake, close = _udp_close}, true
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// init_nbio_mbox allocates a loop_mbox.Mbox wired to the nbio event loop.
//
// kind selects the wake mechanism (default: .UDP).
// Use .Timeout if UDP sockets are unavailable or on Windows where IOCP
// completion packets may interact unexpectedly with UDP at high speed.
//
// Returns (nil, .Invalid_Loop) if loop is nil.
// Returns (nil, .Keepalive_Failed) if the Timeout wakeuper allocation fails.
// Returns (nil, .Socket_Failed) if the UDP socket or bind fails.
//
// Thread model:
//   init_nbio_mbox : any thread
//   send           : any thread
//   try_receive    : event-loop thread only (MPSC single-consumer rule)
//   close          : event-loop thread only (nbio.remove panics cross-thread)
//   destroy        : event-loop thread (after close)
//
// "Event-loop thread" = the one thread calling nbio.tick for the given loop.
init_nbio_mbox :: proc(
	$T: typeid,
	loop: ^nbio.Event_Loop,
	kind := Nbio_Wakeuper_Kind.UDP,
	allocator := context.allocator,
) -> (
	^loop_mbox.Mbox(T),
	Nbio_Mailbox_Error,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node {
	if loop == nil {
		return nil, .Invalid_Loop
	}

	waker: wakeup.WakeUper
	init_ok: bool

	switch kind {
	case .Timeout:
		waker, init_ok = _init_timeout_wakeup(loop, allocator)
		if !init_ok {
			return nil, .Keepalive_Failed
		}
	case .UDP:
		waker, init_ok = _init_udp_wakeup(loop, allocator)
		if !init_ok {
			return nil, .Socket_Failed
		}
	}

	m := loop_mbox.init(T, waker, allocator)
	if m == nil {
		waker.close(waker.ctx)
		return nil, .Keepalive_Failed
	}

	return m, .None
}
