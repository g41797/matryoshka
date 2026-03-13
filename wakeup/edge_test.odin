package wakeup

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// ----------------------------------------------------------------------------
// Edge cases and concurrent tests
// ----------------------------------------------------------------------------

// test_wake_with_nil_ctx verifies that _sema_wake and _sema_close
// are safe no-ops when ctx is nil.
@(test)
test_wake_with_nil_ctx :: proc(t: ^testing.T) {
	_sema_wake(nil)  // must not crash
	_sema_close(nil) // must not crash
	testing.expect(t, true, "nil ctx calls should not crash")
}

_CONCURRENT_WAKERS :: 10

// test_concurrent_wake_signals starts _CONCURRENT_WAKERS threads that each
// call wake once. Verifies the semaphore receives all signals.
@(test)
test_concurrent_wake_signals :: proc(t: ^testing.T) {
	w := sema_wakeup()

	threads := make([dynamic]^thread.Thread, 0, _CONCURRENT_WAKERS)
	defer delete(threads)

	for _ in 0 ..< _CONCURRENT_WAKERS {
		th := thread.create_and_start_with_poly_data(
			&w,
			proc(w: ^WakeUper) {
				w.wake(w.ctx)
			},
		)
		append(&threads, th)
	}

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	state := (^_Sema_State)(w.ctx)
	count := 0
	for sync.sema_wait_with_timeout(&state.sema, 10 * time.Millisecond) {
		count += 1
	}

	testing.expect(t, count == _CONCURRENT_WAKERS, "all wake signals should be received")
	w.close(w.ctx)
}

// _Custom_State holds flags set by a custom WakeUper's wake and close procs.
@(private)
_Custom_State :: struct {
	fired:  bool,
	closed: bool,
}

// test_custom_wakeup builds a WakeUper from raw procs (no semaphore).
// Verifies the interface works with any implementation.
@(test)
test_custom_wakeup :: proc(t: ^testing.T) {
	state := _Custom_State{}

	w := WakeUper {
		ctx   = rawptr(&state),
		wake  = proc(ctx: rawptr) {(^_Custom_State)(ctx).fired = true},
		close = proc(ctx: rawptr) {(^_Custom_State)(ctx).closed = true},
	}

	testing.expect(t, !state.fired, "should not be fired before wake")
	testing.expect(t, !state.closed, "should not be closed before close")

	w.wake(w.ctx)
	testing.expect(t, state.fired, "should be fired after wake")

	w.close(w.ctx)
	testing.expect(t, state.closed, "should be closed after close")
}

// test_ctx_persistence verifies that ctx stored in WakeUper matches
// the allocated _Sema_State address and that the stored allocator is valid.
@(test)
test_ctx_persistence :: proc(t: ^testing.T) {
	w := sema_wakeup()
	state := (^_Sema_State)(w.ctx)

	testing.expect(t, rawptr(state) == w.ctx, "ctx should point to _Sema_State")
	testing.expect(t, state.allocator.procedure != nil, "stored allocator should be valid")

	w.close(w.ctx)
}
