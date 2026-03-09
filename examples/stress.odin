package examples

import mbox ".."
import list "core:container/intrusive/list"
import "core:sync"
import "core:thread"

// stress_example shows high-throughput multi-producer single-consumer messaging.
//
// 10 producer threads each send 1000 messages.
// 1 consumer thread receives all 10,000 messages via wait_receive.
// The example returns true if all messages were received.
//
// Messages are pre-allocated on the heap. Producers index into their slice.
// After the consumer counts all N, it signals done.
// Main waits for done, then closes the mailbox and drains any remaining messages.
stress_example :: proc() -> bool {
	N :: 10_000
	P :: 10

	// Pre-allocate all messages. Producers only write their node links.
	// Safe to free after consumer counts all N.
	msgs := make([]Msg, N)
	defer delete(msgs)

	mb: mbox.Mailbox(Msg)
	done: sync.Sema

	// Consumer: counts N messages then signals done.
	thread.run_with_poly_data2(&mb, &done, proc(mb: ^mbox.Mailbox(Msg), done: ^sync.Sema) {
		count := 0
		for count < N {
			_, err := mbox.wait_receive(mb)
			if err == .Closed {
				break
			}
			if err == .None {
				count += 1
			}
		}
		sync.sema_post(done)
	})

	// P producers: each sends its slice of messages.
	for p in 0 ..< P {
		slice := msgs[p * (N / P) : (p + 1) * (N / P)]
		thread.run_with_poly_data2(&mb, slice, proc(mb: ^mbox.Mailbox(Msg), slice: []Msg) {
			for i in 0 ..< len(slice) {
				mbox.send(mb, &slice[i])
			}
		})
	}

	// Wait for consumer to count all N messages.
	sync.sema_wait(&done)

	// Close and drain any remaining messages.
	// In this flow remaining is empty (consumer got all N), but capturing the
	// return value and draining is correct practice and demonstrates the pattern.
	remaining, _ := mbox.close(&mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		// process or free undelivered messages here
	}

	return true
}
