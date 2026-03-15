package examples

import mbox "../mbox"
import pool_pkg "../pool"
import list "core:container/intrusive/list"
import "core:sync"
import "core:thread"

// _Stress_Consumer owns all ITC participants for the stress test.
// Heap-allocated so producer and consumer threads can hold its address safely.
@(private)
_Stress_Consumer :: struct {
	pool:  pool_pkg.Pool(DisposableMsg),
	inbox: mbox.Mailbox(DisposableMsg),
	done:  sync.Sema,
}

// create_stress_consumer is a factory proc that demonstrates Idiom 11: errdefer-dispose.
// [itc: errdefer-dispose]
create_stress_consumer :: proc(n: int) -> (c: ^_Stress_Consumer, ok: bool) {
	raw := new(_Stress_Consumer) // [itc: heap-master]
	if raw == nil { return }

	c_opt: Maybe(^_Stress_Consumer) = raw
	defer if !ok { _stress_consumer_dispose(&c_opt) }

	init_ok, _ := pool_pkg.init(&raw.pool, initial_msgs = n, max_msgs = n, reset = disposable_reset)
	if !init_ok { return }

	c = raw
	ok = true
	return
}

@(private)
_stress_consumer_dispose :: proc(c: ^Maybe(^_Stress_Consumer)) { // [itc: dispose-contract]
	cp, ok := c.?
	if !ok || cp == nil {return}
	remaining, _ := mbox.close(&cp.inbox)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		msg := container_of(node, DisposableMsg, "node")
		msg_opt: Maybe(^DisposableMsg) = msg
		ptr, accepted := pool_pkg.put(&cp.pool, &msg_opt)
		if !accepted && ptr != nil {
			p_opt: Maybe(^DisposableMsg) = ptr
			disposable_dispose(&p_opt) // [itc: foreign-dispose]
		}
	}
	pool_pkg.destroy(&cp.pool)
	free(cp)
	c^ = nil
}

// stress_example shows many producers, one consumer, with pool recycling.
stress_example :: proc() -> bool {
	N :: 10_000
	P :: 10

	sc, ok := create_stress_consumer(N)
	if !ok {
		return false
	}
	sc_opt: Maybe(^_Stress_Consumer) = sc
	defer _stress_consumer_dispose(&sc_opt) // [itc: defer-dispose]

	// Consumer: receives messages and returns them to the pool.
	consumer_thread := thread.create_and_start_with_data(
		sc,
		proc(data: rawptr) {
			c := (^_Stress_Consumer)(data) // [itc: thread-container]
			count := 0
			for count < N {
				msg, err := mbox.wait_receive(&c.inbox)
				if err == .Closed {
					break
				}
				if err == .None {
					msg_opt: Maybe(^DisposableMsg) = msg // [itc: maybe-container]
					
					// Demonstrating Idiom 2: defer-put with Idiom 6: foreign-dispose
					defer { // [itc: defer-put]
						ptr, accepted := pool_pkg.put(&c.pool, &msg_opt)
						if !accepted && ptr != nil {
							p_opt: Maybe(^DisposableMsg) = ptr
							disposable_dispose(&p_opt) // [itc: foreign-dispose]
						}
					}
					
					count += 1
				}
			}
			sync.sema_post(&c.done)
		},
	)

	// P producers: each gets N/P messages from pool and sends them.
	producer_threads := make([]^thread.Thread, P)
	defer delete(producer_threads)
	for i in 0 ..< P {
		producer_threads[i] = thread.create_and_start_with_data(
			sc,
			proc(data: rawptr) {
				c := (^_Stress_Consumer)(data) // [itc: thread-container]
				for _ in 0 ..< N / P {
					msg, _ := pool_pkg.get(&c.pool)
					if msg != nil {
						msg_opt: Maybe(^DisposableMsg) = msg // [itc: maybe-container]
						
						// Idiom 4: defer-dispose handles cleanup on send failure
						defer disposable_dispose(&msg_opt) // [itc: defer-dispose]
						
						if !mbox.send(&c.inbox, &msg_opt) {
							// msg_opt still non-nil on failure, handled by defer
						}
					}
				}
			},
		)
	}

	sync.sema_wait(&sc.done)

	// Join all threads before dispose.
	for i in 0 ..< P {
		thread.join(producer_threads[i])
		thread.destroy(producer_threads[i])
	}
	thread.join(consumer_thread)
	thread.destroy(consumer_thread)

	return true
}
