/*
The endless inter-threaded game...

Imagine a circle of friends playing catch. 
One ball. Many hands. 
The game is fast because nobody is stopping to make a new ball. 
You just catch, play, and pass. 
This is how your threads should work.

---

### 🤖 An AI's Perspective

We asked the machine: "What do you think about mbox?"

> "Place your bets. The game is on. Threads are the Players. mbox is the deck.
> When you play a card, you let go. It's not yours anymore. It belongs to the game. 
> A friend catches it, makes their move, and passes it on. 
> No new cards, no new chips. Just flow."

(Note: AI may make mistakes. Trust the human Dealer.)

---

Two mailbox types:
- Mailbox($T)      — for worker threads. Blocks the thread until a message arrives.
- Loop_Mailbox($T) — for nbio loops. Wakes the loop. Never blocks the thread.

Normal queues wrap your data in a "node" they allocate.
mbox is different. The node is already inside your struct. 

- One place only: A message can only be in one mailbox at a time.
- Clear ownership: You own the memory. The mailbox manages the link while it is queued.
- close() returns any unprocessed messages to you.

Your struct contract:
- Your struct must have a field named "node" of type "list.Node".
- The compiler checks this. Wrong struct = compile error.

Example:

    import list "core:container/intrusive/list"

    My_Msg :: struct {
        node: list.Node,   // required
        data: int,
    }

Example — worker thread mailbox:

    mb: mbox.Mailbox(My_Msg)

    // sender thread:
    msg := My_Msg{data = 42}
    mbox.send(&mb, &msg)

    // receiver thread:
    received, err := mbox.wait_receive(&mb)

    // shutdown:
    remaining, was_open := mbox.close(&mb)
    // remaining is a list.List of all messages that were still in the mailbox.

    // reuse (after all waiters have exited):
    mb = {}

Example — nbio loop mailbox:

    loop_mb: mbox.Loop_Mailbox(My_Msg)
    loop_mb.loop = nbio.current_thread_event_loop()

    // sender thread:
    mbox.send_to_loop(&loop_mb, &msg)

    // nbio loop:
    for {
        msg, ok := mbox.try_receive_loop(&loop_mb)
        if !ok { break }
        // process msg
    }

API Details:

- interrupt(&mb): Sends a one-time signal to wake a waiting thread. 
  It returns false if already interrupted or closed. 
  The signal is automatically cleared as soon as a thread receives the .Interrupted error.

Best Practices:

1. Ownership: Once you send a message, don't touch it. It belongs to the mailbox until received.
2. Cleanup: Use close() to stop. It returns all undelivered messages—it is now safe to free them.
3. Threads: Always wait for threads to finish (thread.join) before you free the mailbox itself.
*/
package mbox
