// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package wakeup

import "core:mem"
import "core:sync"

// WakeUper is a wake-up callback. Value type — copyable.
// wake and close do NOT use #contextless — callers may use context.logger.
//
// Call wake to signal the consumer that work is available.
// Call close when done — it frees internal resources.
// The zero value is valid. Callers must check wake != nil before calling.
WakeUper :: struct {
	ctx:   rawptr,
	wake:  proc(rawptr),
	close: proc(rawptr),
}

@(private)
_Sema_State :: struct {
	sema:      sync.Sema, // zero value is valid — no init or destroy needed
	allocator: mem.Allocator,
}

// sema_wakeup returns a WakeUper backed by a semaphore.
// Useful for non-nbio loops and unit tests.
// Call waker.close(waker.ctx) when done to free resources.
sema_wakeup :: proc(allocator := context.allocator) -> WakeUper {
	state := new(_Sema_State, allocator)
	state.allocator = allocator
	return WakeUper{ctx = rawptr(state), wake = _sema_wake, close = _sema_close}
}

@(private)
_sema_wake :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_Sema_State)(ctx)
	sync.sema_post(&state.sema)
}

@(private)
_sema_close :: proc(ctx: rawptr) {
	if ctx == nil {
		return
	}
	state := (^_Sema_State)(ctx)
	free(state, state.allocator)
}
