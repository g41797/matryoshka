/*
Package nbio_mbox — concept implementation (experimental).

nbio_mbox is a concept implementation showing how matryoshka can be injected into a foreign
event loop (core:nbio). Tests run on Linux only — the implementation is not production-ready
and is not intended to be. For production use, wire your own wakeup via the WakeUper interface.

It wraps loop_mbox.Mbox with a wakeup mechanism that signals the nbio event loop
when a message is sent from another thread.

Two wake mechanisms are available via Nbio_Wakeuper_Kind:

  .UDP (default) — A loopback UDP socket. The sender writes 1 byte; nbio wakes on receipt.

  .Timeout — Uses nbio.wake_up to signal the event loop. On non-Windows, a 24-hour
      keepalive timer keeps tick() blocking. On Windows, tick() busy-polls (keepalive
      omitted — avl.find_or_insert crashes under aggressive optimisation).

Thread model:

  init_nbio_mbox : any thread
  send (loop_mbox.send) : any thread — lock-free MPSC enqueue + wake signal
  try_receive    : event-loop thread only (MPSC single-consumer rule)
  close          : event-loop thread only (nbio.remove panics cross-thread)
  destroy        : event-loop thread (after close)

"Event-loop thread" is the single thread calling nbio.tick for the given loop.

Quick start:

	loop := nbio.current_thread_event_loop()
	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	defer {
		loop_mbox.close(m)
		loop_mbox.destroy(m)
	}

	// sender thread:
	msg: Maybe(^Msg) = new(Msg)
	loop_mbox.send(m, &msg) // msg = nil after this

	// event-loop thread:
	for {
		nbio.tick(timeout)
		batch := loop_mbox.try_receive_batch(m)
		for node := list.pop_front(&batch); node != nil; node = list.pop_front(&batch) {
			msg := (^Msg)(node)
			_ = msg // handle — free or return to pool
		}
	}


*/
package nbio_mbox
