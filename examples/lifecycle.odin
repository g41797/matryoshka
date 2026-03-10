package examples

import mbox ".."
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

	// 2. Interrupt the game.
	// This wakes up the next waiter with .Interrupted.
	mbox.interrupt(&mb)
	_, err := mbox.wait_receive(&mb)
	if err != .Interrupted {
		free(m)
		return false
	}

	// 3. Send the message.
	// The mailbox now owns the reference (the link).
	mbox.send(&mb, m)

	// 4. Shutdown.
	// close() hands back all references to you.
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
