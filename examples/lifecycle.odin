package examples

import mbox "../mbox"
import list "core:container/intrusive/list"

// lifecycle_example shows the complete flow: 
// 1. Allocation via context.allocator (new).
// 2. Handling an interrupt.
// 3. Closing and cleaning up (free).
lifecycle_example :: proc() -> bool {
	mb: mbox.Mailbox(Msg)

	// 1. Create a message. 
	// You own the memory.
	m := new(Msg)
	m.data = 100

	// 2. Interrupt — no message yet, so the waiter gets .Interrupted.
	// Wakes the next waiter with .Interrupted.
	mbox.interrupt(&mb)
	_, err := mbox.wait_receive(&mb)
	if err != .Interrupted {
		free(m)
		return false
	}

	// 3. Send the message.
	// The mailbox holds the pointer now.
	mbox.send(&mb, m)

	// 4. Shutdown.
	// close() returns all undelivered messages.
	remaining, _ := mbox.close(&mb)

	// 5. Cleanup.
	// You must free anything the mailbox handed back.
	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, Msg, "node")
		free(msg)
		count += 1
	}

	return count == 1
}
