package examples

import mbox "../mbox"
import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:mem"
import "core:strings"
import "core:thread"

// DisposableMsg is a message with an internal heap-allocated field.
// It requires a dispose proc for final cleanup.
// It uses reset for reuse hygiene inside the pool.
DisposableMsg :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	name:      string, // heap-allocated — must be freed before the struct
}

// disposable_reset clears stale state without freeing internal resources.
// Pool calls it automatically on get (before handing to caller) and on put (before free-list).
// Does NOT free name. Pool reuses the slot.
disposable_reset :: proc(msg: ^DisposableMsg, _: pool_pkg.Pool_Event) {
	msg.name = ""
}

// disposable_dispose frees all internal resources, then frees the struct.
// Follows the ^Maybe(^T) contract: nil inner is a no-op. Sets inner to nil on return.
// Caller uses this for permanent cleanup. Pool and mailbox never call it.
disposable_dispose :: proc(msg: ^Maybe(^DisposableMsg)) {
	if msg^ == nil {return}
	ptr := (msg^).?
	if ptr.name != "" {
		delete(ptr.name, ptr.allocator)
	}
	free(ptr, ptr.allocator)
	msg^ = nil
}

// disposable_msg_example shows a full lifecycle with internal resources:
//   producer: pool.get → fill name → send
//   consumer: receive → process → pool.put (reset clears name automatically)
//
// Also shows the error path: if send fails, defer dispose handles cleanup.
disposable_msg_example :: proc() -> bool {
	p: pool_pkg.Pool(DisposableMsg)
	ok, _ := pool_pkg.init(&p, initial_msgs = 4, max_msgs = 0, reset = disposable_reset)
	if !ok {
		return false
	}
	defer pool_pkg.destroy(&p)

	mb: mbox.Mailbox(DisposableMsg)

	result := false

	// Consumer thread: receives one message, checks the name, puts back to pool.
	t := thread.create_and_start_with_poly_data2(
		&mb, &p,
		proc(mb: ^mbox.Mailbox(DisposableMsg), p: ^pool_pkg.Pool(DisposableMsg)) {
			msg, err := mbox.wait_receive(mb)
			if err != .None || msg == nil {
				return
			}
			// process: name is set
			_ = msg.name
			// return to pool — reset runs automatically, clears name
			m: Maybe(^DisposableMsg) = msg
			_, _ = pool_pkg.put(p, &m)
		},
	)

	// Producer: get from pool, fill resources, send.
	msg, status := pool_pkg.get(&p)
	if status != .Ok {
		thread.join(t)
		thread.destroy(t)
		return false
	}

	m: Maybe(^DisposableMsg) = msg
	defer disposable_dispose(&m) // no-op if send succeeded

	m.?.name = strings.clone("hello", m.?.allocator)
	if mbox.send(&mb, &m) {
		result = true
	}
	// if send failed: m is non-nil, defer dispose handles cleanup

	thread.join(t)
	thread.destroy(t)

	return result
}
