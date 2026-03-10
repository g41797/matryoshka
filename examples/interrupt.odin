package examples

import mbox ".."
import "core:thread"
import "core:time"

// interrupt_example shows how to wake up a waiting thread without sending a message.
interrupt_example :: proc() -> bool {
	mb: mbox.Mailbox(Msg)
	err_result: mbox.Mailbox_Error

	// Start a thread that will wait forever.
	t := thread.create_and_start_with_poly_data2(&mb, &err_result, proc(mb: ^mbox.Mailbox(Msg), res: ^mbox.Mailbox_Error) {
		_, err := mbox.wait_receive(mb)
		res^ = err
	})

	// Give it a moment to start waiting.
	time.sleep(10 * time.Millisecond)

	// Wake it up!
	mbox.interrupt(&mb)

	thread.join(t)
	thread.destroy(t)

	// It should have been interrupted.
	return err_result == .Interrupted
}
