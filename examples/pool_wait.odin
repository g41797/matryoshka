package examples

import mbox "../mbox"
import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:sync"
import "core:thread"

N_PLAYERS :: 6
M_TOKENS  :: 2 // fewer tokens than players — forces waiting

ROUNDS    :: 5

// pool_wait_example shows N players sharing M tokens (M < N).
// Players must wait (pool.get .Pool_Only, timeout=-1) until a token is returned.
pool_wait_example :: proc() -> bool {
	p: pool_pkg.Pool(Msg)
	if ok, _ := pool_pkg.init(&p, initial_msgs = M_TOKENS, max_msgs = M_TOKENS, reset = nil); !ok {
		return false
	}

	mb: mbox.Mailbox(Msg)
	done: sync.Sema

	// Collector: receives all messages and returns each token to pool.
	thread.run_with_poly_data3(
		&mb, &p, &done,
		proc(mb: ^mbox.Mailbox(Msg), p: ^pool_pkg.Pool(Msg), done: ^sync.Sema) {
			total :: N_PLAYERS * ROUNDS
			count := 0
			for count < total {
				msg, err := mbox.wait_receive(mb)
				if err == .Closed {
					break
				}
				if err == .None {
					msg_opt: Maybe(^Msg) = msg
					_, _ = pool_pkg.put(p, &msg_opt)
					count += 1
				}
			}
			sync.sema_post(done)
		},
	)

	// N_PLAYERS players: each waits for a token, then sends it.
	// Only M_TOKENS tokens exist — excess players block in pool.get until one is returned.
	for _ in 0 ..< N_PLAYERS {
		thread.run_with_poly_data2(
			&mb, &p,
			proc(mb: ^mbox.Mailbox(Msg), p: ^pool_pkg.Pool(Msg)) {
				for _ in 0 ..< ROUNDS {
					msg, status := pool_pkg.get(p, .Pool_Only, -1)
					if status == .Closed {
						break
					}
					msg_opt: Maybe(^Msg) = msg
					if !mbox.send(mb, &msg_opt) {
						_, _ = pool_pkg.put(p, &msg_opt)
					}
				}
			},
		)
	}

	sync.sema_wait(&done)

	remaining, _ := mbox.close(&mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, Msg, "node")
		msg_opt: Maybe(^Msg) = msg
		_, _ = pool_pkg.put(&p, &msg_opt)
	}
	pool_pkg.destroy(&p)
	return true
}
