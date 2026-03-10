package examples

import mbox ".."
import list "core:container/intrusive/list"
import "core:thread"
import "core:time"

// close_example shows how to stop the game and get all messages back.
close_example :: proc() -> bool {
	mb: mbox.Mailbox(Msg)
	err_result: mbox.Mailbox_Error

	// 1. Start a waiter thread BEFORE adding messages.
	t := thread.create_and_start_with_poly_data2(&mb, &err_result, proc(mb: ^mbox.Mailbox(Msg), res: ^mbox.Mailbox_Error) {
		_, err := mbox.wait_receive(mb)
		res^ = err
	})

	// Give it a moment to start waiting.
	time.sleep(10 * time.Millisecond)

	// 2. Add some messages to the mailbox.
	a := Msg{data = 1}
	b := Msg{data = 2}
	mbox.send(&mb, &a)
	mbox.send(&mb, &b)

	// 3. Close the mailbox. This wakes all waiters.
	// It also returns all messages that were still in the queue.
	remaining, _ := mbox.close(&mb)

	// Verify we got 2 messages back.
	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		count += 1
	}

	thread.join(t)
	thread.destroy(t)

	// Success if:
	// - 2 messages were returned.
	// - The waiter got .Closed.
	return count == 2 && err_result == .Closed
}
