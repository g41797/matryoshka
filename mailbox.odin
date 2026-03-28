// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package matryoshka

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:sync"
import "core:time"

@(private)
_Node :: list.Node
@(private)
_Mutex :: sync.Mutex
@(private)
_Duration :: time.Duration

SendResult :: enum {
	Ok,
	Closed,
	Invalid,
}

RecvResult :: enum {
	Ok,
	Closed,
	Interrupted,
	Already_In_Use,
	Invalid,
	Timeout,
}

IntrResult :: enum {
	Ok,
	Closed,
	Already_Interrupted,
}

@(private = "file")
_Mbox :: struct {
	using poly:  PolyNode,
	mutex:       sync.Mutex,
	cond:        sync.Cond,
	list:        list.List,
	len:         int,
	closed:      bool,
	interrupted: bool,
}


Mailbox :: distinct ^_Mbox

unwrap :: proc(m: Mailbox) -> ^_Mbox {
	return cast(^_Mbox)m
}

mbox_send :: proc(mb: Mailbox, m: ^MayItem) -> SendResult {
	if (m == nil) || (m^ == nil) || (unwrap(mb).id == 0) {
		return .Invalid
	}


	return .Ok
}
