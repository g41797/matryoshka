# mbox — Examples and Patterns

mbox is intrusive. The message struct is the node. No extra allocation per message.

---

## 1. Basic send and receive

```odin
import mbox "path/to/odin-mbox"
import list "core:container/intrusive/list"

Msg :: struct {
    node: list.Node,  // required
    data: int,
}

// Sender:
msg := Msg{data = 42}
ok := mbox.send(&mb, &msg)

// Receiver (non-blocking poll):
got, err := mbox.wait_receive(&mb, 0)  // err == .Timeout means no message

// Receiver (blocking, infinite wait):
got, err := mbox.wait_receive(&mb)

// Receiver (blocking, with timeout):
got, err := mbox.wait_receive(&mb, 100 * time.Millisecond)
```

---

## 2. Tagged envelope pattern (multiple message types)

One mailbox. Multiple message types. Use a common base struct with a kind field.

```odin
import mbox "path/to/odin-mbox"
import list "core:container/intrusive/list"
import "core:fmt"

Msg_Kind :: enum {
    Process_Image,
    Save_File,
    Shutdown,
}

// Base struct. All message types start with this.
Envelope :: struct {
    node: list.Node,  // required
    kind: Msg_Kind,
}

// Specific message type. Embeds Envelope.
Image_Msg :: struct {
    using base: Envelope,
    width:      int,
    height:     int,
}

// Send:
img := new(Image_Msg)
img.kind = .Process_Image
img.width = 1920
mbox.send(&mb, &img.base)  // send the base Envelope

// Receive and dispatch:
got, err := mbox.wait_receive(&mb)
if err == .None {
    switch got.kind {
    case .Process_Image:
        full := (^Image_Msg)(got)
        fmt.printf("Processing %d wide image\n", full.width)
        free(full)
    case .Save_File:
        // ...
    case .Shutdown:
        // ...
    }
}
```

Note: for this pattern, `mb` is `mbox.Mailbox(Envelope)`.

---

## 3. Graceful shutdown

```odin
// Sender signals shutdown (capture remaining if drain is needed — see Pattern 8):
_, _ = mbox.close(&mb)

// Receiver checks for it:
msg, err := mbox.wait_receive(&mb)
switch err {
case .None:
    // process msg
case .Closed:
    // mailbox is closed, stop receiving
case .Timeout:
    // timed out, check other conditions
case .Interrupted:
    // interrupted, stop or retry
}
```

---

## 4. Interrupt for cancellation

The interrupted flag is self-clearing: `wait_receive` clears it when it returns `.Interrupted`.
`interrupt()` returns false if already interrupted or closed.

```odin
// From any thread, cancel one waiter:
ok := mbox.interrupt(&mb)

// The waiting thread gets .Interrupted:
msg, err := mbox.wait_receive(&mb)
if err == .Interrupted {
    // stop work
}

// The flag is now cleared. A subsequent interrupt() will succeed.
// To reuse the mailbox after all waiters have exited, assign zero value:
// mb = {}
```

---

## 5. nbio loop mailbox — request-reply

Worker thread sends a request to the nbio loop. The loop replies via a regular mailbox.

```odin
// Setup (on the loop thread):
loop_mb: mbox.Loop_Mailbox(Req)
loop_mb.loop = nbio.current_thread_event_loop()

reply_mb: mbox.Mailbox(Reply)

// Worker thread:
req := Req{data = 10}
mbox.send_to_loop(&loop_mb, &req)

reply, err := mbox.wait_receive(&reply_mb)

// nbio loop — drain on wake:
for {
    req, ok := mbox.try_receive_loop(&loop_mb)
    if !ok { break }
    r := Reply{data = req.data + 1}
    mbox.send(&reply_mb, &r)
}
```

See `examples/negotiation.odin` for a working version of this pattern.

---

## 6. High-throughput stress pattern

Many producers, one consumer.

```odin
// Consumer thread:
for {
    msg, err := mbox.wait_receive(&mb)
    if err == .Closed { break }
    // process msg
}

// Each producer thread:
for i in 0 ..< N {
    mbox.send(&mb, &msgs[i])
}

// After all producers finish (capture remaining if drain is needed — see Pattern 8):
_, _ = mbox.close(&mb)
```

See `examples/stress.odin` for a working version of this pattern.

---

## 7. One place only — remove before send

A `list.Node` can only be in one list at a time.
If your struct is already in another intrusive list, remove it first.

```odin
// Remove from existing list before sending to mailbox:
list.remove(&other_list, &msg.node)
ok := mbox.send(&mb, &msg)
```

Do not send a message that is already queued. The result is a broken list.

---

## 8. Drain unprocessed messages after close

`close()` and `close_loop()` return the remaining list of unprocessed messages.
Iterate it to process or free them.

```odin
remaining, was_open := mbox.close(&mb)
for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
    msg := container_of(node, Msg, "node")
    // process or free msg
}
```

While a message is queued, the mailbox owns the node.
`close()` transfers ownership back to the caller.

To reuse after close (after all waiters have exited):

```odin
// 1. Close and drain remaining messages.
remaining, _ := mbox.close(&mb)
// drain remaining...

// 2. Wait for all threads that were using this mailbox to exit.

//  step 3. Reinitialize via zero assignment — all fields reset correctly.
mb = {}
```

---

## 9. Relay Race / Endless Game (Circular Passing)

Pass a single message between multiple threads in a circle.
Ownership moves from Runner 1 to 2, 2 to 3, and so on.

```odin
// Runner i:
for {
    baton, err := mbox.wait_receive(my_mb)
    if err != .None { break }

    // process baton...

    mbox.send(next_mb, baton)
}
```

This pattern is perfect for:
- State machines where different threads handle different states.
- High-speed pipelines with zero data copies.
- Games where one "entity" is manipulated by many systems.

See `examples/endless_game.odin` for the full implementation.
