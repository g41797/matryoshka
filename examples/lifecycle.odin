package examples

import mbox "../mbox"
import list "core:container/intrusive/list"

@(private)
_Lifecycle_Master :: struct {
	mb: mbox.Mailbox(Msg),
}

@(private)
_lifecycle_dispose :: proc(m: ^Maybe(^_Lifecycle_Master)) { // [itc: dispose-contract]
	mp, ok := m.?
	if !ok || mp == nil { return }
	
	// Final drain: after close, all returned messages need dispose.
	// Demonstrating Idiom 8: dispose-optional
	remaining, _ := mbox.close(&mp.mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, Msg, "node")
		msg_opt: Maybe(^Msg) = msg
		_msg_dispose(&msg_opt) // [itc: dispose-optional]
	}
	free(mp)
	m^ = nil
}

// lifecycle_example shows the complete flow: 
// 1. Allocation via context.allocator (new).
// 2. Handling an interrupt.
// 3. Closing and cleaning up (free).
lifecycle_example :: proc() -> bool {
	m := new(_Lifecycle_Master) // [itc: heap-master]
	m_opt: Maybe(^_Lifecycle_Master) = m
	defer _lifecycle_dispose(&m_opt) // [itc: defer-dispose]

	// 1. Create a message.
	// You own the memory.
	msg: Maybe(^Msg) = new(Msg) // [itc: maybe-container]
	msg.?.allocator = context.allocator

	// 2. Interrupt — no message yet, so the waiter gets .Interrupted.
	// Wakes the next waiter with .Interrupted.
	mbox.interrupt(&m.mb)
	_, err := mbox.wait_receive(&m.mb)
	if err != .Interrupted {
		_msg_dispose(&msg)
		return false
	}

	// 3. Send the message.
	// The mailbox holds the pointer now.
	ok := mbox.send(&m.mb, &msg)
	if !ok {
		_msg_dispose(&msg)
		return false
	}

	// 4. Shutdown.
	// Handled by defer _lifecycle_dispose(&m_opt) which drains the mailbox.

	return true
}
