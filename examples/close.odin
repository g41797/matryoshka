package examples

import mbox ".."
import list "core:container/intrusive/list"
import "core:thread"
import "core:time"

// close_example shows how to stop the game and get all messages back.
close_example :: proc() -> bool {
	mb: mbox.Mailbox(Msg)

	// --- Part 1: close() wakes waiters ---
	// We use an empty mailbox to ensure the waiter blocks.
	err_result: mbox.Mailbox_Error
	t := thread.create_and_start_with_poly_data2(&mb, &err_result, proc(mb: ^mbox.Mailbox(Msg), res: ^mbox.Mailbox_Error) {
		_, err := mbox.wait_receive(mb)
		res^ = err
	})

	// Wait for the thread to be inside wait_receive.
	time.sleep(10 * time.Millisecond)

	// Close the empty mailbox. This must wake the waiter with .Closed.
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
	// Reset the mailbox for a fresh start.
	mb = {} 
	
	// Create two messages. 
	a := Msg{data = 1}
	b := Msg{data = 2}
	
	// Send them. Mailbox now owns the references.
	mbox.send(&mb, &a)
	mbox.send(&mb, &b)

	// Close and get all undelivered messages back.
	remaining, _ := mbox.close(&mb)

	// Verify we got both references back.
	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		count += 1
	}

	return count == 2
}
