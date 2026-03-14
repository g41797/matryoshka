// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

package try_mbox

import "base:intrinsics"
import list "core:container/intrusive/list"
import "core:mem"
import mpsc "../mpsc"
import wakeup "../wakeup"

// -vet workarounds: generic struct field types are not counted as import usage.
@(private) _MQ :: mpsc.Queue(struct {node: list.Node})
@(private) _MW :: wakeup.WakeUper
@(private) _MA :: mem.Allocator
@(private) _MN :: list.Node

// Mbox is a non-blocking mailbox backed by a lock-free MPSC queue.
// Not copyable after init — internal pointers reference fields inside the struct.
// Use init to allocate on the heap. Use destroy to free when done.
// T must have a field named "node" of type list.Node.
Mbox :: struct($T: typeid) {
	queue:     mpsc.Queue(T),
	waker:     wakeup.WakeUper,
	closed:    bool, // atomic
	allocator: mem.Allocator, // stored for destroy
}

// init allocates and initializes a new Mbox on the heap.
// waker is optional: zero value = no notification on send.
// Not copyable after return — pass the pointer, never copy the struct.
init :: proc(
	$T: typeid,
	waker := wakeup.WakeUper{},
	allocator := context.allocator,
) -> ^Mbox(T) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	m := new(Mbox(T), allocator)
	if m == nil {
		return nil
	}
	m.allocator = allocator
	m.waker = waker
	mpsc.init(&m.queue)
	return m
}

// send adds msg to the queue and calls waker.wake if set.
// Returns false if the mailbox is closed. Safe to call from multiple threads.
send :: proc(m: ^Mbox($T), msg: ^T) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if intrinsics.atomic_load(&m.closed) {
		return false
	}
	mpsc.push(&m.queue, msg)
	if m.waker.wake != nil {
		m.waker.wake(m.waker.ctx)
	}
	return true
}

// try_receive pops one message without blocking. Single-consumer only.
// Returns (nil, false) if the queue is empty, in a stall state, or closed.
// On stall (length > 0 but nil returned): caller retries on the next tick. Do not
// call in a tight loop — busy-polling defeats the non-blocking contract.
try_receive :: proc(m: ^Mbox($T)) -> (^T, bool) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	msg := mpsc.pop(&m.queue)
	return msg, msg != nil
}

// try_receive_all pops all available messages without blocking. Single-consumer only.
// Returns an empty list if the queue is empty or in stall state.
// On stall: some in-flight messages may not appear — caller retries on the next tick.
try_receive_all :: proc(m: ^Mbox($T)) -> list.List where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	result: list.List
	for {
		msg := mpsc.pop(&m.queue)
		if msg == nil {break}
		list.push_back(&result, &msg.node)
	}
	return result
}

// close marks the mailbox closed, calls waker.close, and drains remaining messages.
// Returns (remaining, true) on first call; ({}, false) if already closed.
// Caller must drain the returned list — free heap messages or return to pool.
// Must be called from the consumer thread — drains with mpsc.pop (single-consumer).
// Precondition: all senders have stopped (threads joined). After that, no stall
// window can be active — each sender's push (atomic exchange + next-pointer write)
// is fully visible once the thread is joined.
close :: proc(m: ^Mbox($T)) -> (list.List, bool) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if intrinsics.atomic_exchange(&m.closed, true) {
		return {}, false
	}
	if m.waker.close != nil {
		m.waker.close(m.waker.ctx)
	}
	remaining: list.List
	for {
		msg := mpsc.pop(&m.queue)
		if msg == nil {
			break
		}
		list.push_back(&remaining, &msg.node)
	}
	return remaining, true
}

// length returns the approximate number of messages in the queue.
// May be > 0 while try_receive returns nil (stall state — see package doc).
length :: proc(m: ^Mbox($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	return mpsc.length(&m.queue)
}

// destroy frees the heap memory allocated by init.
// Call after close and after draining all remaining messages.
destroy :: proc(m: ^Mbox($T)) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	free(m, m.allocator)
}
