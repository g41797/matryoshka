package examples

import mbox "../mbox"
import list "core:container/intrusive/list"
import "core:thread"
import "core:time"

@(private)
_Close_Master :: struct {
	mb: mbox.Mailbox(Itm),
}

@(private)
_close_dispose :: proc(m: ^Maybe(^_Close_Master)) { // [itc: dispose-contract]
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

// close_example shows how to stop a mailbox and get all undelivered items back.
close_example :: proc() -> bool {
	m := new(_Close_Master) // [itc: heap-master]
	m_opt: Maybe(^_Close_Master) = m
	defer _close_dispose(&m_opt) // [itc: defer-dispose]

	// --- Part 1: close() wakes a blocked waiter ---
	err_result: mbox.Mailbox_Error
	t := thread.create_and_start_with_poly_data2(&m.mb, &err_result, proc(mb: ^mbox.Mailbox(Itm), res: ^mbox.Mailbox_Error) {
		// [itc: thread-container] (mb is part of heap-master)
		_, err := mbox.wait_receive(mb)
		res^ = err
	})

	// Wait for the thread to enter wait_receive.
	time.sleep(10 * time.Millisecond)

	// Close the empty mailbox. Waiter must wake with .Closed.
	_, was_open := mbox.close(&m.mb)
	if !was_open {
		return false
	}

	thread.join(t)
	thread.destroy(t)

	if err_result != .Closed {
		return false
	}

	// --- Part 2: close() returns undelivered items ---
	// Reset the mailbox for the next part.
	m.mb = {}

	// Allocate two items on the heap.
	a: Maybe(^Itm) = new(Itm) // [itc: maybe-container]
	a.?.allocator = context.allocator

	b: Maybe(^Itm) = new(Itm) // [itc: maybe-container]
	b.?.allocator = context.allocator

	// Send them. Mailbox now owns the references.
	if !mbox.send(&m.mb, &a) {
		_itm_dispose(&a)
		_itm_dispose(&b)
		return false
	}
	if !mbox.send(&m.mb, &b) {
		_itm_dispose(&b)
		return false
	}

	// Close and get all undelivered items back.
	remaining, _ := mbox.close(&m.mb)

	// Free each returned item.
	count := 0
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		itm := container_of(node, Itm, "node")
		itm_opt: Maybe(^Itm) = itm
		_itm_dispose(&itm_opt) // [itc: dispose-optional]
		count += 1
	}

	return count == 2
}
