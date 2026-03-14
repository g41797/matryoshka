// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package mbox

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:sync"
import "core:time"

// _Node and _Mutex keep -vet happy — it does not count generic field types as import usage.
@(private)
_Node :: list.Node
@(private)
_Mutex :: sync.Mutex
@(private)
_Duration :: time.Duration

Mailbox_Error :: enum {
	None,
	Timeout,
	Closed,
	Interrupted,
}

// Mailbox is for worker threads. It blocks using a condition variable.
// T must have a field named "node" of type list.Node.
Mailbox :: struct($T: typeid) {
	mutex:       sync.Mutex,
	cond:        sync.Cond,
	list:        list.List,
	len:         int,
	closed:      bool,
	interrupted: bool,
}

// send adds msg to the mailbox and wakes one waiting thread.
// nil inner (msg^ == nil) is a no-op and returns false.
// closed: returns false, msg^ unchanged (caller retains ownership).
// success: msg^ = nil, returns true.
send :: proc(m: ^Mailbox($T), msg: ^Maybe(^T)) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if msg^ == nil {
		return false
	}
	ptr := (msg^).?
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	if m.closed {
		return false
	}
	list.push_back(&m.list, &ptr.node)
	m.len += 1
	msg^ = nil
	sync.cond_signal(&m.cond)
	return true
}

// wait_receive blocks until a message arrives, the mailbox closes, or timeout.
// Use timeout < 0 for infinite wait.
wait_receive :: proc(
	m: ^Mailbox($T),
	timeout: time.Duration = -1,
) -> (
	msg: ^T,
	err: Mailbox_Error,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node {
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)

	if m.len > 0 {
		msg = _pop(m)
		sync.cond_signal(&m.cond)
		return msg, .None
	}
	if m.closed {
		return nil, .Closed
	}
	if m.interrupted {
		m.interrupted = false
		return nil, .Interrupted
	}
	if timeout == 0 {
		return nil, .Timeout
	}

	for m.len == 0 {
		ok: bool
		if timeout < 0 {
			sync.cond_wait(&m.cond, &m.mutex)
			ok = true
		} else {
			ok = sync.cond_wait_with_timeout(&m.cond, &m.mutex, timeout)
		}
		if m.closed {
			return nil, .Closed
		}
		if m.interrupted {
			m.interrupted = false
			return nil, .Interrupted
		}
		if !ok {
			return nil, .Timeout
		}
	}

	msg = _pop(m)
	sync.cond_signal(&m.cond)
	return msg, .None
}

// interrupt wakes one waiting thread. It returns false if already interrupted or closed.
// The interrupted flag is self-clearing: wait_receive clears it when returning .Interrupted.
interrupt :: proc(m: ^Mailbox($T)) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	sync.mutex_lock(&m.mutex)
	if m.closed || m.interrupted {
		sync.mutex_unlock(&m.mutex)
		return false
	}
	m.interrupted = true
	sync.mutex_unlock(&m.mutex)
	sync.cond_signal(&m.cond)
	return true
}

// close prevents new messages, wakes all waiting threads with .Closed,
// and returns any unprocessed messages as a list.List.
// Returns (remaining, true) on first call; ({}, false) if already closed.
// Reuse: after all waiters have exited, assign zero value: mb = {}
close :: proc(
	m: ^Mailbox($T),
) -> (
	remaining: list.List,
	was_open: bool,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node {
	sync.mutex_lock(&m.mutex)
	if m.closed {
		sync.mutex_unlock(&m.mutex)
		return {}, false
	}
	m.closed = true
	m.interrupted = false
	remaining = m.list
	m.list = {}
	m.len = 0
	sync.mutex_unlock(&m.mutex)
	sync.cond_broadcast(&m.cond)
	return remaining, true
}

// _pop removes and returns the front message. Caller must hold m.mutex.
@(private)
_pop :: proc(m: ^Mailbox($T)) -> ^T where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	raw := list.pop_front(&m.list)
	m.len -= 1
	return container_of(raw, T, "node")
}
