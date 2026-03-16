package examples

import mbox "../mbox"
import nbio_mbox "../nbio_mbox"
import loop_mbox "../loop_mbox"
import list "core:container/intrusive/list"
import "core:nbio"
import "core:thread"

// _Worker holds the loop mailbox, reply mailbox, and the result.
// Heap-allocated so the worker thread can hold its address safely.
@(private)
_Worker :: struct {
	loop_mb:  ^loop_mbox.Mbox(DisposableItm),
	reply_mb: mbox.Mailbox(DisposableItm),
	ok:       bool,
}

// create_worker is a factory proc that demonstrates Idiom 11: errdefer-dispose.
// [itc: errdefer-dispose]
create_worker :: proc(loop: ^nbio.Event_Loop, kind: nbio_mbox.Nbio_Wakeuper_Kind) -> (w: ^_Worker, ok: bool) {
	raw := new(_Worker) // [itc: heap-master]
	if raw == nil { return }

	w_opt: Maybe(^_Worker) = raw
	defer if !ok { _worker_dispose(&w_opt) }

	// loop_mb receives requests from the worker.
	init_err: nbio_mbox.Nbio_Mailbox_Error
	raw.loop_mb, init_err = nbio_mbox.init_nbio_mbox(DisposableItm, loop, kind)
	if init_err != .None {
		return
	}

	w = raw
	ok = true
	return
}

@(private)
_worker_dispose :: proc(w: ^Maybe(^_Worker)) { // [itc: dispose-contract]
	wp, ok := w.?
	if !ok || wp == nil {return}

	// Dispose loop_mb
	if wp.loop_mb != nil {
		remaining_loop, _ := loop_mbox.close(wp.loop_mb)
		for node := list.pop_front(&remaining_loop); node != nil; node = list.pop_front(&remaining_loop) {
			itm := (^DisposableItm)(node)
			itm_opt: Maybe(^DisposableItm) = itm
			disposable_dispose(&itm_opt) // [itc: dispose-optional]
		}
		loop_mbox.destroy(wp.loop_mb)
	}

	// Dispose reply_mb
	remaining, _ := mbox.close(&wp.reply_mb)
	for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
		itm := (^DisposableItm)(node)
		itm_opt: Maybe(^DisposableItm) = itm
		disposable_dispose(&itm_opt) // [itc: dispose-optional]
	}

	free(wp)
	w^ = nil
}

// negotiation_example shows request-reply between a worker thread and an nbio event loop.
negotiation_example :: proc(kind: nbio_mbox.Nbio_Wakeuper_Kind = .UDP) -> bool {
	err := nbio.acquire_thread_event_loop()
	if err != nil {
		return false
	}
	defer nbio.release_thread_event_loop()

	loop := nbio.current_thread_event_loop()

	w, ok := create_worker(loop, kind)
	if !ok {
		return false
	}
	w_opt: Maybe(^_Worker) = w
	defer _worker_dispose(&w_opt) // [itc: defer-dispose]

	// Worker: allocates request, sends to loop, waits for reply, frees reply.
	t := thread.create_and_start_with_poly_data(w, proc(w: ^_Worker) { // [itc: thread-container]
		req: Maybe(^DisposableItm) = new(DisposableItm) // [itc: maybe-container]
		req.?.allocator = context.allocator

		// Idiom 4: defer-dispose handles cleanup on send failure
		defer disposable_dispose(&req) // [itc: defer-dispose]

		if !loop_mbox.send(w.loop_mb, &req) {
			return
		}

		// Worker allocated req; loop will send it back as reply.
		reply, recv_err := mbox.wait_receive(&w.reply_mb)
		w.ok = recv_err == .None && reply != nil
		if reply != nil {
			reply_opt: Maybe(^DisposableItm) = reply
			disposable_dispose(&reply_opt) // [itc: dispose-optional]
		}
	})

	// Event loop: tick until request arrives, increment data, send back as reply.
	for {
		tick_err := nbio.tick()
		if tick_err != nil {
			break
		}
		nb := loop_mbox.try_receive_batch(w.loop_mb)
		node := list.pop_front(&nb)
		if node != nil {
			// Reuse the received item as the reply.
			itm_inner := (^DisposableItm)(node)
			itm: Maybe(^DisposableItm) = itm_inner

			// Idiom 4: defer-dispose handles cleanup on send failure
			defer disposable_dispose(&itm) // [itc: defer-dispose]

			if !mbox.send(&w.reply_mb, &itm) {
				// handled by defer
			}
			break
		}
	}

	thread.join(t)
	thread.destroy(t)

	return w.ok
}
