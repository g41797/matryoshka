// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package mbox

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import "core:nbio"
import "core:time"
import try_mbox "./try_mbox"
import wakeup "./wakeup"

// -vet workarounds: some import usages are not detected in all contexts.
@(private) _NBioList :: list.Node
@(private) _NBioDuration :: time.Duration
@(private) _NBioWaker :: wakeup.WakeUper

// _NBio_State holds the nbio event loop and keepalive timer for one nbio_mbox instance.
@(private)
_NBio_State :: struct {
	loop:         ^nbio.Event_Loop,
	keepalive:    ^nbio.Operation,
	allocator:    mem.Allocator,
	ref_count:    int,  // atomic
	wake_pending: bool, // atomic — guards the cross-thread timeout queue (capacity 128)
}

// _noop is the required no-op callback for nbio operations (used by keepalive timer).
@(private)
_noop :: proc(_: ^nbio.Operation) {}

// _noop_clear clears the wake_pending flag and releases a reference.
// Runs in the event-loop thread after timeout fires.
@(private)
_noop_clear :: proc(_: ^nbio.Operation, state: ^_NBio_State) {
	intrinsics.atomic_store(&state.wake_pending, false)
	if intrinsics.atomic_add(&state.ref_count, -1) == 1 {
		free(state, state.allocator)
	}
}

// _nbio_wake fires a zero-duration timeout to wake the nbio event loop.
// Uses an atomic CAS flag so at most one timeout is queued at a time, preventing
// the 128-slot cross-thread queue from overflowing under high-frequency sends.
@(private)
_nbio_wake :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_NBio_State)(ctx)
	// CAS false→true. Returns old value; if old != false, wake already pending — skip.
	if intrinsics.atomic_compare_exchange_strong(&state.wake_pending, false, true) != false {
		return
	}
	// Take a reference for the pending timeout task.
	intrinsics.atomic_add(&state.ref_count, 1)
	nbio.timeout_poly(0, state, _noop_clear, state.loop)
}

// _nbio_close removes the keepalive timer and releases the primary reference.
// Must be called from the event-loop thread — nbio.remove panics cross-thread.
// If a _noop_clear callback is pending (wake_pending was true at close time),
// nbio.tick(0) drains it so _noop_clear can decrement ref_count to 0 and free state.
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
	if intrinsics.atomic_add(&state.ref_count, -1) == 1 {
		free(state, state.allocator) // no pending callback — free now
	} else {
		nbio.tick(0) // drain pending _noop_clear → it will free state
	}
}

// Loop_Mailbox_Error is the error returned by init_nbio_mbox.
Loop_Mailbox_Error :: enum {
	None,
	Invalid_Loop,
	Keepalive_Failed,
}

// init_nbio_mbox allocates a try_mbox.Mbox wired to the nbio event loop.
// Returns (nil, .Invalid_Loop) if loop is nil.
// Returns (nil, .Keepalive_Failed) if keepalive timer or Mbox allocation fails.
//
// Thread model:
//   init_nbio_mbox : any thread   — nbio.timeout uses cross-thread queue when loop ≠ current thread
//   send           : any thread   — _nbio_wake uses timeout_poly (cross-thread safe)
//   try_receive    : event-loop thread only — MPSC single-consumer rule
//   close          : event-loop thread only — nbio.remove panics cross-thread
//   destroy        : event-loop thread (after close)
//
// "Event-loop thread" = the one thread calling nbio.tick for the given loop.
init_nbio_mbox :: proc(
	$T: typeid,
	loop: ^nbio.Event_Loop,
	allocator := context.allocator,
) -> (^try_mbox.Mbox(T), Loop_Mailbox_Error) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if loop == nil {
		return nil, .Invalid_Loop
	}
	state := new(_NBio_State, allocator)
	if state == nil {
		return nil, .Keepalive_Failed
	}
	state.loop = loop
	state.allocator = allocator
	state.ref_count = 1 // Held by the Mbox/WakeUper.
	state.keepalive = nbio.timeout(time.Hour * 24, _noop, loop)
	if state.keepalive == nil {
		free(state, allocator)
		return nil, .Keepalive_Failed
	}
	waker := wakeup.WakeUper{ctx = rawptr(state), wake = _nbio_wake, close = _nbio_close}
	m := try_mbox.init(T, waker, allocator)
	if m == nil {
		_nbio_close(rawptr(state))
		return nil, .Keepalive_Failed
	}
	return m, .None
}
