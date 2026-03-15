/*
Package examples contains runnable demos for odin-itc.

Each proc returns true on success.

Patterns shown:
- lifecycle: alloc, interrupt, shutdown, cleanup.
- negotiation: request-reply with an nbio loop.
- interrupt: wake a waiting thread without a message.
- close: stop a mailbox, get undelivered messages back.
- stress: many producers, one consumer, pool recycling.
- endless_game: circular passing of a heap-allocated message.
- master: pool + mailbox owned by one struct, coordinated shutdown.
- disposable_msg: message with internal heap resources — pool.get, fill, send, receive, pool.put with reset. dispose proc for permanent cleanup.

Message allocation rules:
- Never use stack-allocated messages across threads.
  The stack frame can be freed before the receiving thread reads the message.
- Use new/free for simple, low-frequency use.
- Use pool for many messages.
*/
package examples
