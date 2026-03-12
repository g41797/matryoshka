/*
Package pool is a thread-safe free-list for reusable message objects.

Use it with mbox when you need high-throughput recycling.

How it works:
- Call init to set up the pool and pre-allocate messages.
- Call get to take a message from the pool (or allocate a new one).
- Send the message via mbox.
- After receiving, call put to return the message to the pool.
- Call destroy when done. It frees all remaining pool messages.

The pool reuses the same "node" field that mbox requires.
A message is never in both the pool and a mailbox at the same time.

Your struct must have a field named "node" of type list.Node.

	import list "core:container/intrusive/list"

	My_Msg :: struct {
	    node: list.Node, // required by both pool and mbox
	    data: int,
	}
*/
package pool
