/*
Inter-thread mailbox library for Odin. Thread-safe. Zero-allocation.

Two mailbox types:
- Mailbox($T)      — for worker threads. Blocks using condition variable.
- Loop_Mailbox($T) — for nbio event loops. Wakes loop using nbio.wake_up.

This library is intrusive. The link node lives inside your struct.
The mailbox does not allocate anything per message.
Your struct must stay alive while it is in the mailbox.

User struct contract:

Your struct must have a field named "node" of type list.Node.
The field name is fixed. It is not configurable.

Example:

    import list "core:container/intrusive/list"

    My_Msg :: struct {
        node: list.Node,   // required — field name must be "node"
        data: int,
    }

This contract is enforced at compile time.
If your struct does not have a "node: list.Node" field,
the compiler will give an error.

Example — worker thread mailbox:

    mb: mbox.Mailbox(My_Msg)

    // sender thread:
    msg := My_Msg{data = 42}
    mbox.send(&mb, &msg)

    // receiver thread:
    received, err := mbox.wait_receive(&mb)

Example — nbio loop mailbox:

    loop_mb: mbox.Loop_Mailbox(My_Msg)
    loop_mb.loop = nbio.current_thread_event_loop()

    // sender thread:
    mbox.send_to_loop(&loop_mb, &msg)

    // nbio loop — drain on wake:
    for {
        msg, ok := mbox.try_receive_loop(&loop_mb)
        if !ok { break }
        // process msg
    }
*/
package mbox
