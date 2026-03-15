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
//   .Timeout — nbio.wake_up (APC/signal); tick busy-polls when no ops are outstanding
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

// _NBio_State holds the nbio event loop pointer for one nbio_mbox instance.
// The .Timeout variant uses nbio.wake_up to signal the event loop. Because
// no keepalive operation is registered, nbio.tick returns immediately when
// the pool has no outstanding operations; the consumer loop busy-polls
// try_receive_batch between tick calls. This is correct on all platforms and
// avoids all cross-thread nbio operation machinery that is problematic on Windows.
@(private)
_NBio_State :: struct {
	loop:      ^nbio.Event_Loop,
	allocator: mem.Allocator,
}

// _nbio_wake wakes the nbio event loop via nbio.wake_up.
// Uses QueueUserAPC on Windows — no cross-thread operation allocation.
// Safe to call from any thread.
@(private)
_nbio_wake :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_NBio_State)(ctx)
	nbio.wake_up(state.loop)
}

// _nbio_close frees the state.
// Safe to call from any thread (no nbio operations to remove).
@(private)
_nbio_close :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_NBio_State)(ctx)
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
// Shutdown order on Windows (IOCP):
//   CancelIoEx (via nbio.remove) is asynchronous: it posts a STATUS_CANCELLED
//   completion to the IOCP but does not wait for it. If recv_sock is still open
//   when nbio.tick(0) runs, that completion may not have arrived yet, so tick(0)
//   returns without processing it. The stale completion then fires during a
//   subsequent tick call — after state has been freed — and recv_callback reads
//   op.recv._impl.bufs[0].data, which points into the freed state.recv_buf: UAF.
//
//   Fix: close recv_sock BEFORE nbio.remove. Closing the socket forces the pending
//   WSARecvFrom to complete immediately with an error. The IOCP completion is
//   queued synchronously, so the following tick(0) reliably drains it before
//   state is freed. No dangling buffer pointer survives into the next tick.
//
// On Linux/macOS, nbio.remove is silent (callback never fires) and tick(0) is
// a no-op, so the order of close and remove does not matter there.
@(private)
_udp_close :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_UDP_State)(ctx)
	intrinsics.atomic_store(&state.closed, true)
	// Close recv_sock first so the pending WSARecvFrom completes immediately;
	// tick(0) then reliably drains the IOCP completion before state is freed.
	net.close(state.recv_sock)
	if state.recv_op != nil {
		nbio.remove(state.recv_op)
		state.recv_op = nil
	}
	nbio.tick(0) // drain IOCP completion before freeing state.recv_buf
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
