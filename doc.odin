/*
Package mbox is an inter-thread communication library for Odin.

Core concepts:
- Zero copies: Messages are linked, not copied.
- Intrusive: Your message struct must have a field named "node" of type "list.Node".
- Thread-safe: Safe to use from multiple threads.

Mailbox types:
- Mailbox($T): For worker threads. Blocks until a message arrives.
- Loop_Mailbox($T): For nbio event loops. Wakes the loop instead of blocking.

Basic Requirement:
    import list "core:container/intrusive/list"

    My_Msg :: struct {
        node: list.Node, // required
        data: int,
    }
*/
package mbox
