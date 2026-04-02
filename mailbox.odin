// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package matryoshka

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import "core:sync"
import "core:time"

////////////////////
Mailbox :: ^PolyNode
////////////////////


@(private)
_Mbox :: struct {
	using poly:  PolyNode,
	alctr:       mem.Allocator,
	mutex:       sync.Mutex,
	cond:        sync.Cond,
	list:        list.List,
	len:         int,
	closed:      bool,
	interrupted: bool,
}

mbox_new :: proc(alloc: mem.Allocator) -> Mailbox {

	mbx, err := new(_Mbox, alloc)
	if err != .None {
		return nil
	}

	mbx^.alctr = alloc
	mbx^.id = MAILBOX_ID

	return cast(Mailbox)mbx
}

SendResult :: enum {
	Ok,
	Closed,
	Invalid,
}

mbox_send :: proc(mb: Mailbox, m: ^MayItem) -> SendResult {

	mbx_Ptr := _unwrap(mb)

	if mbx_Ptr^.id != MAILBOX_ID {
		panic("non-mailbox is used for mailbox operations")
	}

	if m == nil || m^ == nil {
		return .Invalid
	}

	ptr, ok := m^.?

	if !ok {
		return .Invalid
	}

	if ptr^.id == 0 {
		return .Invalid
	}


	sync.mutex_lock(&mbx_Ptr^.mutex)
	defer sync.mutex_unlock(&mbx_Ptr^.mutex)


	if (mbx_Ptr^.closed) {
		return .Closed
	}

	// Sending a linked node corrupts the list silently.
	// A loud panic here is cheaper than hunting corruption later.
	if polynode_is_linked(ptr) {
		panic("mbox_send: node is still linked — detach before sending")
	}

	list.push_back(&mbx_Ptr^.list, &ptr^.node)

	mbx_Ptr^.len += 1

	m^ = nil

	sync.cond_signal(&mbx_Ptr^.cond)


	return .Ok
}

RecvResult :: enum {
	Ok,
	Closed,
	Interrupted,
	Already_In_Use,
	Invalid,
	Timeout,
}

mbox_wait_receive :: proc(mb: Mailbox, m: ^MayItem, timeout: time.Duration = -1) -> RecvResult {


	mbx_Ptr := _unwrap(mb)

	if mbx_Ptr^.id != MAILBOX_ID {
		panic("non-mailbox is used for mailbox operations")
	}

	infinite := timeout < 0
	start := time.now()

	if m == nil {
		return .Invalid
	}

	if m^ != nil {
		return .Already_In_Use
	}

	sync.mutex_lock(&mbx_Ptr^.mutex)
	defer sync.mutex_unlock(&mbx_Ptr^.mutex)

	for mbx_Ptr^.len == 0 {

		if mbx_Ptr^.closed {
			return .Closed
		}

		if mbx_Ptr^.interrupted {
			mbx_Ptr^.interrupted = false
			return .Interrupted
		}

		if infinite {
			sync.cond_wait(&mbx_Ptr^.cond, &mbx_Ptr^.mutex)
			continue
		}

		elapsed := time.since(start)
		if elapsed >= timeout {
			return .Timeout
		}

		remaining := timeout - elapsed
		sync.cond_wait_with_timeout(&mbx_Ptr^.cond, &mbx_Ptr^.mutex, remaining)

	}

	// Priority: check for data even if closed or interrupted.
	// This ensures no data is lost if it arrived just before or during signal.

	if mbx_Ptr^.len > 0 {
		m^ = _pop(mbx_Ptr)
		sync.cond_signal(&mbx_Ptr^.cond)
		return .Ok
	}

	if mbx_Ptr^.closed {
		return .Closed
	}

	if mbx_Ptr^.interrupted {
		mbx_Ptr^.interrupted = false
		return .Interrupted
	}

	return .Timeout // Should not be reached if len > 0 was checked properly
}

try_receive_batch :: proc(mb: Mailbox) -> (list.List, RecvResult) {


	mbx_Ptr := _unwrap(mb)

	if mbx_Ptr^.id != MAILBOX_ID {
		panic("non-mailbox is used for mailbox operations")
	}

	result := list.List{}

	sync.mutex_lock(&mbx_Ptr^.mutex)
	defer sync.mutex_unlock(&mbx_Ptr^.mutex)

	// Return data if available, even if closed or interrupted.
	if mbx_Ptr^.len > 0 {
		result = mbx_Ptr^.list
		mbx_Ptr^.list = list.List{}
		mbx_Ptr^.len = 0
		sync.cond_signal(&mbx_Ptr^.cond)
		return result, .Ok
	}

	if mbx_Ptr^.closed {
		return result, .Closed
	}

	if mbx_Ptr^.interrupted {
		mbx_Ptr^.interrupted = false
		return result, .Interrupted
	}

	return result, .Ok

}

IntrResult :: enum {
	Ok,
	Closed,
	Already_Interrupted,
}


mbox_interrupt :: proc(mb: Mailbox) -> IntrResult {

	mbx_Ptr := _unwrap(mb)

	if mbx_Ptr^.id != MAILBOX_ID {
		panic("non-mailbox is used for mailbox operations")
	}


	sync.mutex_lock(&mbx_Ptr^.mutex)
	defer sync.mutex_unlock(&mbx_Ptr^.mutex)

	if mbx_Ptr^.closed {
		return .Closed
	}

	if mbx_Ptr^.interrupted {
		return .Already_Interrupted
	}

	mbx_Ptr^.interrupted = true
	sync.cond_signal(&mbx_Ptr^.cond)

	return .Ok
}


mbox_close :: proc(mb: Mailbox) -> list.List {


	mbx_Ptr := _unwrap(mb)

	if mbx_Ptr^.id != MAILBOX_ID {
		panic("non-mailbox is used for mailbox operations")
	}

	result := list.List{}

	sync.mutex_lock(&mbx_Ptr^.mutex)
	defer sync.mutex_unlock(&mbx_Ptr^.mutex)

	if mbx_Ptr^.closed {
		return result
	}

	result = mbx_Ptr^.list
	mbx_Ptr^.list = list.List{}
	mbx_Ptr^.len = 0

	mbx_Ptr^.closed = true
	sync.cond_broadcast(&mbx_Ptr^.cond)

	return result

}

@(private)
_unwrap :: proc(m: Mailbox) -> ^_Mbox {
	return cast(^_Mbox)m
}

@(private)
_pop :: proc(m: ^_Mbox) -> ^PolyNode {
	raw := list.pop_front(&m^.list)
	m^.len -= 1
	result := cast(^PolyNode)raw
	polynode_reset(result)
	return result
}

@(private)
_mbox_dispose :: proc(m: ^MayItem) {
	ptr, _ := m^.?
	mb := cast(^_Mbox)ptr
	if !mb.closed {
		panic("matryoshka_dispose: mailbox must be closed first")
	}
	alloc := mb.alctr
	free(mb, alloc)
	m^ = nil
}

