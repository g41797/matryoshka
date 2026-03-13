/*
Package wakeup provides a wake-up callback interface for event loops.

WakeUper is a value type with three fields: ctx, wake, close.
It is copyable. The zero value is valid — callers must check wake != nil before calling.

sema_wakeup returns a WakeUper backed by a semaphore.
Use it in non-nbio loops and unit tests.

Usage:

	w := wakeup.sema_wakeup()
	defer w.close(w.ctx)

	// From another thread or goroutine:
	w.wake(w.ctx)

	// In the event loop — wait for wake:
	// (depends on your loop mechanism)

Call close when done. close frees internal resources.
*/
package wakeup
