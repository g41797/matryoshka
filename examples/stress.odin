package examples

import mbox "../mbox"
import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:sync"
import "core:thread"

// stress_example shows many producers, one consumer, with pool recycling.
//
// - 10 producers each send 1,000 messages (10,000 total).
// - 1 consumer receives all messages and returns each to the pool.
// - Pool is pre-allocated with N messages. Messages come from the pool. No new allocations while running.
// - After the consumer counts all N, main closes and destroys the pool.
stress_example :: proc() -> bool {
	N :: 10_000
	P :: 10

	// Pre-allocate N messages. Producers get from pool; consumer puts back.
	shared_pool: pool_pkg.Pool(Msg)
	if ok, _ := pool_pkg.init(&shared_pool, initial_msgs = N, max_msgs = N, reset = nil); !ok {
		return false
	}

	mb: mbox.Mailbox(Msg)
	done: sync.Sema

	// Consumer: receives messages and returns them to the pool.
	thread.run_with_poly_data3(
		&mb,
		&shared_pool,
		&done,
		proc(mb: ^mbox.Mailbox(Msg), p: ^pool_pkg.Pool(Msg), done: ^sync.Sema) {
			count := 0
			for count < N {
				msg, err := mbox.wait_receive(mb)
				if err == .Closed {
					break
				}
				if err == .None {
					msg_opt: Maybe(^Msg) = msg
					pool_pkg.put(p, &msg_opt)
					count += 1
				}
			}
			sync.sema_post(done)
		},
	)

	// P producers: each gets N/P messages from pool and sends them.
	for _ in 0 ..< P {
		thread.run_with_poly_data2(
			&mb,
			&shared_pool,
			proc(mb: ^mbox.Mailbox(Msg), p: ^pool_pkg.Pool(Msg)) {
				for _ in 0 ..< N / P {
					msg, _ := pool_pkg.get(p)
					if msg != nil {
						msg_opt: Maybe(^Msg) = msg
						mbox.send(mb, &msg_opt)
					}
				}
			},
		)
	}

	sync.sema_wait(&done)

	// Drain any remaining messages back to pool before destroy.
	remaining, _ := mbox.close(&mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, Msg, "node")
		msg_opt: Maybe(^Msg) = msg
		pool_pkg.put(&shared_pool, &msg_opt)
	}

	pool_pkg.destroy(&shared_pool)
	return true
}
