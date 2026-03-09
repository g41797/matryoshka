// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package mbox

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:sync"

// _LoopNode, _LoopMutex, _Loop ensure imports are used — required by -vet for generic code.
@(private)
_LoopNode :: list.Node
@(private)
_LoopMutex :: sync.Mutex
@(private)
_Loop :: nbio.Event_Loop

// Loop_Mailbox is for nbio event loops. It does not block.
// It wakes the loop using nbio.wake_up.
// T must have a field named "node" of type list.Node.
Loop_Mailbox :: struct($T: typeid) {
	mutex:  sync.Mutex,
	list:   list.List,
	len:    int,
	loop:   ^nbio.Event_Loop,
	closed: bool,
}

// send_to_loop adds msg to the mailbox and wakes the nbio loop if needed.
// Returns false if the mailbox is closed.
send_to_loop :: proc(
	m: ^Loop_Mailbox($T),
	msg: ^T,
) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") ==
	list.Node {
	sync.mutex_lock(&m.mutex)
	defer sync.mutex_unlock(&m.mutex)
	if m.closed {
		return false
	}
	was_empty := m.len == 0
	list.push_back(&m.list, &msg.node)
	m.len += 1
	if was_empty {
		nbio.wake_up(m.loop)
	}
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

// close_loop prevents new messages, wakes the loop one last time,
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
	sync.mutex_unlock(&m.mutex)
	nbio.wake_up(m.loop)
	return remaining, true
}

// stats returns the current number of pending messages.
// Not locked — value is approximate.
stats :: proc(m: ^Loop_Mailbox($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	return m.len
}
