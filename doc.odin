/*
Package mbox is an intrusive inter-thread mailbox library for Odin.

It provides zero-allocation message passing between threads by linking your existing 
structs directly into the mailbox.

Core concepts:
- Zero allocations: Messages are linked, not copied.
- Intrusive: Your message struct must have a field named "node" of type "list.Node".
- Thread-safe: Designed for high-concurrency "endless" games or data flows.

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
