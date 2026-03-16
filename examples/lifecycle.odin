package examples

import mbox "../mbox"
import list "core:container/intrusive/list"

@(private)
_Lifecycle_Master :: struct {
	mb: mbox.Mailbox(Itm),
}

@(private)
_lifecycle_dispose :: proc(m: ^Maybe(^_Lifecycle_Master)) { // [itc: dispose-contract]
	mp, ok := m.?
	if !ok || mp == nil { return }

	// Final drain: after close, all returned items need dispose.
	// Demonstrating Idiom 8: dispose-optional
	remaining, _ := mbox.close(&mp.mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		itm := container_of(node, Itm, "node")
		itm_opt: Maybe(^Itm) = itm
		_itm_dispose(&itm_opt) // [itc: dispose-optional]
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

	// 1. Create an item.
	// You own the memory.
	itm: Maybe(^Itm) = new(Itm) // [itc: maybe-container]
	itm.?.allocator = context.allocator

	// 2. Interrupt — no item yet, so the waiter gets .Interrupted.
	// Wakes the next waiter with .Interrupted.
	mbox.interrupt(&m.mb)
	_, err := mbox.wait_receive(&m.mb)
	if err != .Interrupted {
		_itm_dispose(&itm)
		return false
	}

	// 3. Send the item.
	// The mailbox holds the pointer now.
	ok := mbox.send(&m.mb, &itm)
	if !ok {
		_itm_dispose(&itm)
		return false
	}

	// 4. Shutdown.
	// Handled by defer _lifecycle_dispose(&m_opt) which drains the mailbox.

	return true
}
