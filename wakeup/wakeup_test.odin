package wakeup

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// ----------------------------------------------------------------------------
// Unit tests
// ----------------------------------------------------------------------------

@(test)
test_zero_value :: proc(t: ^testing.T) {
	w: WakeUper
	testing.expect(t, w.ctx == nil, "zero value ctx should be nil")
	testing.expect(t, w.wake == nil, "zero value wake should be nil")
	testing.expect(t, w.close == nil, "zero value close should be nil")
}

@(test)
test_sema_wakeup_creates :: proc(t: ^testing.T) {
	w := sema_wakeup()
	testing.expect(t, w.ctx != nil, "ctx should not be nil")
	testing.expect(t, w.wake != nil, "wake should not be nil")
	testing.expect(t, w.close != nil, "close should not be nil")
	w.close(w.ctx)
}

@(test)
test_sema_wake_signals :: proc(t: ^testing.T) {
	w := sema_wakeup()
	w.wake(w.ctx)
	state := (^_Sema_State)(w.ctx)
	ok := sync.sema_wait_with_timeout(&state.sema, 100 * time.Millisecond)
	testing.expect(t, ok, "wake should signal the semaphore")
	w.close(w.ctx)
}

@(test)
test_sema_close_frees :: proc(t: ^testing.T) {
	// Memory tracker catches any leak if close does not free.
	w := sema_wakeup()
	w.close(w.ctx)
}

// ----------------------------------------------------------------------------
// Example
// ----------------------------------------------------------------------------

@(private)
_example_sema_wakeup :: proc() -> bool {
	w := sema_wakeup()

	th := thread.create_and_start_with_poly_data(&w, proc(w: ^WakeUper) {
		time.sleep(5 * time.Millisecond)
		w.wake(w.ctx)
	})

	state := (^_Sema_State)(w.ctx)
	ok := sync.sema_wait_with_timeout(&state.sema, 500 * time.Millisecond)

	thread.join(th)
	thread.destroy(th)
	w.close(w.ctx)
	return ok
}

@(test)
test_example_sema_wakeup :: proc(t: ^testing.T) {
	testing.expect(t, _example_sema_wakeup(), "sema wakeup example should succeed")
}
