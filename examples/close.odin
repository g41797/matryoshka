package examples

import mbox ".."
import list "core:container/intrusive/list"
import "core:thread"
import "core:time"

// close_example shows how to stop a mailbox and get all undelivered messages back.
close_example :: proc() -> bool {
	mb: mbox.Mailbox(Msg)

	// --- Part 1: close() wakes a blocked waiter ---
	err_result: mbox.Mailbox_Error
	t := thread.create_and_start_with_poly_data2(&mb, &err_result, proc(mb: ^mbox.Mailbox(Msg), res: ^mbox.Mailbox_Error) {
		_, err := mbox.wait_receive(mb)
		res^ = err
	})

	// Wait for the thread to enter wait_receive.
	time.sleep(10 * time.Millisecond)

	// Close the empty mailbox. Waiter must wake with .Closed.
	_, was_open := mbox.close(&mb)
	if !was_open {
		return false
	}

	thread.join(t)
	thread.destroy(t)

	if err_result != .Closed {
		return false
	}

	// --- Part 2: close() returns undelivered messages ---
	mb = {}

	// Allocate two messages on the heap.
	a := new(Msg)
	a.data = 1
	b := new(Msg)
	b.data = 2

	// Send them. Mailbox now owns the references.
	mbox.send(&mb, a)
	mbox.send(&mb, b)

	// Close and get all undelivered messages back.
	remaining, _ := mbox.close(&mb)

	// Free each returned message.
	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, Msg, "node")
		free(msg)
		count += 1
	}

	return count == 2
}
