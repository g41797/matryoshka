package examples

import mbox "../mbox"
import pool_pkg "../pool"
import list "core:container/intrusive/list"

// Master owns a pool and a mailbox together.
// One struct. One shutdown call. No leaks.
Master :: struct {
	pool:  pool_pkg.Pool(Msg),
	inbox: mbox.Mailbox(Msg),
}

// master_init sets up the pool with 8 pre-allocated messages and a cap of 64.
master_init :: proc(m: ^Master) -> bool {
	ok, _ := pool_pkg.init(&m.pool, initial_msgs = 8, max_msgs = 64, reset = nil)
	return ok
}

// master_shutdown closes the inbox, returns undelivered messages to the pool, then destroys the pool.
//
// Order matters:
// - Return messages to pool BEFORE destroy.
// - Calling destroy first would make the returned pointers invalid.
master_shutdown :: proc(m: ^Master) {
	remaining, _ := mbox.close(&m.inbox)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, Msg, "node")
		msg_opt: Maybe(^Msg) = msg
		_, _ = pool_pkg.put(&m.pool, &msg_opt) // back to pool, not freed
	}
	pool_pkg.destroy(&m.pool)
}

// master_example shows pool + mailbox owned by one struct, with coordinated shutdown.
//
// Flow:
// - init: pool pre-allocated, ready to use.
// - get a message from pool, send to inbox.
// - shutdown: inbox closed, message returned to pool, pool destroyed.
master_example :: proc() -> bool {
	m: Master
	if !master_init(&m) {
		return false
	}

	msg, _ := pool_pkg.get(&m.pool)
	if msg == nil {
		master_shutdown(&m)
		return false
	}
	msg_opt: Maybe(^Msg) = msg
	msg_opt.?.data = 42
	ok := mbox.send(&m.inbox, &msg_opt)
	if !ok {
		// send failed — return message to pool before shutdown
		// msg_opt is still non-nil (send failed, caller retains ownership)
		_, _ = pool_pkg.put(&m.pool, &msg_opt)
		master_shutdown(&m)
		return false
	}

	master_shutdown(&m)
	return true
}
