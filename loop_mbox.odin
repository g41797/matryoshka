// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package mbox

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:sync"
import "core:time"

// _LoopNode, _LoopMutex, _Loop keep -vet happy — it does not count generic field types as import usage.
@(private)
_LoopNode :: list.Node
@(private)
_LoopMutex :: sync.Mutex
@(private)
_Loop :: nbio.Event_Loop
@(private)
_LoopDuration :: time.Duration

// Loop_Mailbox is a command queue for an nbio event loop.
// It does not block. It manages its own wake-up and keepalive logic.
// T must have a field named "node" of type list.Node.
Loop_Mailbox :: struct($T: typeid) {
	mutex:     sync.Mutex,
	list:      list.List,
	len:       int,
	loop:      ^nbio.Event_Loop,
	keepalive: ^nbio.Operation, // hidden timer to keep loop active
	closed:    bool,
}

// _noop is the required callback for nbio tasks. It does nothing.
@(private)
_noop :: proc(_: ^nbio.Operation) {}

// init_loop_mailbox sets up the mailbox for an nbio loop.
// It creates a hidden keepalive timer so nbio.tick() blocks correctly on all platforms.
init_loop_mailbox :: proc(m: ^Loop_Mailbox($T), loop: ^nbio.Event_Loop) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	m.loop = loop
	m.keepalive = nbio.timeout(time.Hour * 24, _noop, loop)
}

// send_to_loop adds msg to the mailbox and wakes the nbio loop.
// Returns false if the mailbox is closed.
send_to_loop :: proc(
	m: ^Loop_Mailbox($T),
	msg: ^T,
) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node {
	sync.mutex_lock(&m.mutex)
	if m.closed {
		sync.mutex_unlock(&m.mutex)
		return false
	}

	list.push_back(&m.list, &msg.node)
	m.len += 1
	sync.mutex_unlock(&m.mutex)

	// Add a no-op task so the loop checks our queue before it sleeps.
	nbio.timeout(0, _noop, m.loop)
	return true
}

// try_receive_loop returns one message without blocking.
// Call in a loop until ok is false to drain the mailbox.
try_receive_loop :: proc(
	m: ^Loop_Mailbox($T),
) -> (
	msg: ^T,
	ok: bool,
) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node {
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	if m.len == 0 {
		return nil, false
	}
	raw := list.pop_front(&m.list)
	m.len -= 1
	return container_of(raw, T, "node"), true
}

// close_loop prevents new messages, stops the keepalive timer,
// and returns any unprocessed messages as a list.List.
// Returns (remaining, true) on first call; ({}, false) if already closed.
close_loop :: proc(m: ^Loop_Mailbox($T)) -> (remaining: list.List, was_open: bool) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	sync.mutex_lock(&m.mutex)
	if m.closed {
		sync.mutex_unlock(&m.mutex)
		return {}, false
	}
	m.closed = true
	remaining = m.list
	m.list = {}
	m.len = 0

	// Stop the keepalive timer.
	op := m.keepalive
	m.keepalive = nil
	sync.mutex_unlock(&m.mutex)

	if op != nil {
		nbio.remove(op)
	}

	// Final wake-up so the loop sees the close.
	nbio.timeout(0, _noop, m.loop)
	return remaining, true
}

// stats returns the current number of pending messages.
// Not locked — value is approximate.
stats :: proc(m: ^Loop_Mailbox($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	return m.len
}
