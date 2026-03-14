/*
Package nbio_mbox provides a non-blocking mailbox for nbio event loops.

It wraps try_mbox.Mbox with a wakeup mechanism that signals the nbio event loop
when a message is sent from another thread.

Two wake mechanisms are available via Nbio_Wakeuper_Kind:

  .UDP (default) — A loopback UDP socket. The sender writes 1 byte; nbio wakes on
      receipt. Stable on Linux, macOS, and Windows. No queue capacity limit.

  .Timeout — A zero-duration nbio timeout. Limited by the 128-slot cross-thread
      queue; throttled with a CAS flag to prevent overflow under high-frequency sends.

Thread model:

  init_nbio_mbox : any thread
  send (try_mbox.send) : any thread — lock-free MPSC enqueue + wake signal
  try_receive    : event-loop thread only (MPSC single-consumer rule)
  close          : event-loop thread only (nbio.remove panics cross-thread)
  destroy        : event-loop thread (after close)

"Event-loop thread" is the single thread calling nbio.tick for the given loop.

Quick start:

	loop := nbio.current_thread_event_loop()
	m, err := nbio_mbox.init_nbio_mbox(Msg, loop)
	defer {
		try_mbox.close(m)
		try_mbox.destroy(m)
	}

	// sender thread:
	try_mbox.send(m, msg)

	// event-loop thread:
	for {
		nbio.tick(timeout)
		msg, ok := try_mbox.try_receive(m)
		if ok { /* handle */ }
	}
*/
package nbio_mbox
