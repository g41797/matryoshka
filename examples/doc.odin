/*
Package examples contains runnable demos for matryoshka.

Each proc returns true on success.

Patterns shown:
- lifecycle: alloc, interrupt, shutdown, cleanup.
- negotiation: request-reply with an nbio loop.
- interrupt: wake a waiting thread without a message.
- close: stop a mailbox, get undelivered messages back.
- stress: many producers, one consumer, pool recycling.
- endless_game: circular passing of a heap-allocated message.
- master: pool + mailbox owned by one struct, coordinated shutdown.
- disposable_itm: item with internal heap resources — pool.get, fill, send, receive, pool.put with reset. dispose proc for permanent cleanup.
- echo_server: raw mpsc.Queue + sync.Sema echo server — shows the building blocks of loop_mbox.

Item allocation rules:
- Never use stack-allocated items across threads.
  The stack frame can be freed before the receiving thread reads the item.
- Use new/free for simple, low-frequency use.
- Use pool for many items.
*/
package examples
