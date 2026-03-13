package examples

import mbox ".."
import list "core:container/intrusive/list"
import "core:mem"
import "core:nbio"
import "core:thread"

// Msg is the shared message type for all examples.
// "node" is required by mbox (and pool). The name is fixed. The type is list.Node.
// "allocator" is required by pool — set by pool.get on every retrieval.
Msg :: struct {
	node:      list.Node,
	allocator: mem.Allocator,
	data:      int,
}

// _Worker holds pointers to both mailboxes and the result.
@(private)
_Worker :: struct {
	loop_mb:  ^mbox.Loop_Mailbox(Msg),
	reply_mb: ^mbox.Mailbox(Msg),
	ok:       bool,
}

// negotiation_example shows request-reply between a worker thread and an nbio event loop.
//
// Flow:
//   worker  →  Loop_Mailbox  →  nbio loop
//   nbio loop →  Mailbox  →  worker
//
// - Worker allocates a request on the heap, sends it to the loop.
// - Loop receives the request. Reuses it as the reply (increments data, sends back).
// - Worker receives the reply and frees it.
// - One allocation per round-trip. Worker owns the memory start to finish.
negotiation_example :: proc() -> bool {
	err := nbio.acquire_thread_event_loop()
	if err != nil {
		return false
	}
	defer nbio.release_thread_event_loop()

	loop := nbio.current_thread_event_loop()

	// loop_mb receives requests from the worker.
	loop_mb: mbox.Loop_Mailbox(Msg)
	mbox.init_loop_mailbox(&loop_mb, loop)

	// reply_mb sends replies back to the worker.
	reply_mb: mbox.Mailbox(Msg)

	w := _Worker{loop_mb = &loop_mb, reply_mb = &reply_mb}

	// Worker: allocates request, sends to loop, waits for reply, frees reply.
	t := thread.create_and_start_with_poly_data(&w, proc(w: ^_Worker) {
		req := new(Msg)
		req.data = 10
		mbox.send_to_loop(w.loop_mb, req)

		// Worker allocated req; loop will send it back as reply.
		reply, recv_err := mbox.wait_receive(w.reply_mb)
		w.ok = recv_err == .None && reply != nil && reply.data == 11
		if reply != nil {
			free(reply) // worker frees what it allocated
		}
	})

	// Event loop: tick until request arrives, increment data, send back as reply.
	for {
		tick_err := nbio.tick()
		if tick_err != nil {
			break
		}
		msg, ok := mbox.try_receive_loop(&loop_mb)
		if ok {
			// Reuse the received message as the reply.
			// No extra allocation needed. Ownership stays with the worker.
			msg.data = msg.data + 1
			mbox.send(&reply_mb, msg)
			break
		}
	}

	thread.join(t)
	thread.destroy(t)

	return w.ok
}
