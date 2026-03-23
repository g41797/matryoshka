# mbox — Examples and Patterns

mbox is intrusive. The message struct is the node. No extra allocation per message.

---

## 1. Basic send and receive

Allocate messages on the heap. Never pass stack-allocated messages across threads.

```odin
import mbox "path/to/matryoshka"
import list "core:container/intrusive/list"

Msg :: struct {
    node: list.Node,  // required
    data: int,
}

// Sender thread:
msg: Maybe(^Msg) = new(Msg)
msg.?.data = 42
mbox_send(&mb, &msg) // msg = nil after this — mailbox owns it

// Receiver (non-blocking poll):
got: Maybe(^Msg)
err := mbox.wait_receive(&mb, &got, 0)  // err == .Timeout means no message
if got != nil { free(got.?) }

// Receiver (blocking, infinite wait):
got: Maybe(^Msg)
err := mbox.wait_receive(&mb, &got)
if got != nil { free(got.?) }

// Receiver (blocking, with timeout):
got: Maybe(^Msg)
err := mbox.wait_receive(&mb, &got, 100 * time.Millisecond)
if got != nil { free(got.?) }
```

---

## 2. Tagged envelope pattern (multiple message types)

One mailbox. Multiple message types. Use a common base struct with a kind field.

```odin
import mbox "path/to/matryoshka"
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
env: Maybe(^Envelope) = &img.base
mbox_send(&mb, &env)  // env = nil after this

// Receive and dispatch:
got: Maybe(^Envelope)
err := mbox.wait_receive(&mb, &got)
if err == .None && got != nil {
    switch got.?.kind {
    case .Process_Image:
        full := (^Image_Msg)(got.?)
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

## 3. "Graceful" shutdown

```odin
// Sender signals shutdown (capture remaining if drain is needed — see Pattern 8):
_, _ = mbox.close(&mb)

// Receiver checks for it:
msg: Maybe(^Msg)
err := mbox.wait_receive(&mb, &msg)
switch err {
case .None:
    // process msg, then free it
    free(msg.?)
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
msg: Maybe(^Msg)
err := mbox.wait_receive(&mb, &msg)
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
loop := nbio.current_thread_event_loop()
mbox.init_loop_mailbox(&loop_mb, loop)

reply_mb: mbox.Mailbox(Reply)

// Worker thread: allocate request, send, wait for reply, free reply.
req := new(Req)
req.data = 10
mbox.send_to_loop(&loop_mb, req)

reply: Maybe(^Reply)
err := mbox.wait_receive(&reply_mb, &reply)
if reply != nil {
    // use reply.?.data
    free(reply.?) // worker frees what it allocated
}

// nbio loop — drain on wake, reuse received message as reply:
for {
    req, ok := mbox.try_receive_loop(&loop_mb)
    if !ok { break }
    req.data = req.data + 1   // modify in place
    mbox_send(&reply_mb, req) // send same object back — worker will free it
}
```

See `examples/negotiation.odin` for a working version of this pattern.

---

## 6. High-throughput stress pattern

Many producers, one consumer. Use a pool for zero-allocation recycling.

```odin
import pool_pkg "path/to/matryoshka/pool"

// Setup:
shared_pool: pool_pkg.Pool(Msg)
pool_pkg.init(&shared_pool, initial_msgs = N, max_msgs = N)

// Consumer thread:
for {
    msg: Maybe(^Msg)
    err := mbox.wait_receive(&mb, &msg)
    if err == .Closed { break }
    pool_pkg.put(&shared_pool, &msg)  // return to pool
}

// Each producer thread:
for _ in 0 ..< N / P {
    msg: Maybe(^Msg)
    if pool_pkg.get(&shared_pool, &msg) == .Ok {
        mbox_send(&mb, &msg)
    }
}

// After done:
pool_pkg.destroy(&shared_pool)
```

See `examples/stress.odin` for a working version of this pattern.

---

## 7. One place only — remove before send

A `list.Node` can only be in one list at a time.
If your struct is already in another intrusive list, remove it first.

```odin
// msg must be heap-allocated or from a pool — never stack-allocated.
// Remove from existing list before sending to mailbox:
list.remove(&other_list, &msg.node)
ok := mbox_send(&mb, msg)
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
    free(msg)        // heap: free it
    // pool_pkg.put(&p, msg) // pool: return it
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

Pass a single heap-allocated message between multiple threads in a circle.
Ownership moves from Runner 1 to 2, 2 to 3, and so on.
One thread allocates the message. One thread frees it after the game ends.

```odin
// Before starting threads: allocate once on the heap.
baton: Maybe(^Msg) = new(Msg)
mbox_send(&mboxes[0], &baton)

// Runner i:
for {
    baton: Maybe(^Msg)
    err := mbox.wait_receive(my_mb, &baton)
    if err != .None { break }

    // process baton...

    mbox_send(next_mb, &baton)
}

// After all threads exit: free the baton if still held.
// (It is in exactly one mailbox or held by one thread at close time.)
```

This pattern is perfect for:
- State machines where different threads handle different states.
- High-speed pipelines with zero data copies.
- Games where one "entity" is manipulated by many systems.

See `examples/endless_game.odin` for the full implementation.

---

## 10. Pool usage (init / get / put / destroy)

Use a pool when you send many messages and want to avoid repeated heap allocations.

```odin
import pool_pkg "path/to/matryoshka/pool"

// Setup (once, before any threads start):
p: pool_pkg.Pool(Msg)
pool_pkg.init(&p, initial_msgs = 64, max_msgs = 256)

// Sender thread: take from pool, fill data, send.
msg: Maybe(^Msg)
if pool_pkg.get(&p, &msg) == .Ok {
    msg.?.data = 42
    mbox_send(&mb, &msg)
}

// Receiver thread: receive, use, return to pool.
got: Maybe(^Msg)
err := mbox.wait_receive(&mb, &got)
if err == .None {
    // use got.?.data
    pool_pkg.put(&p, &got)
}

// Cleanup (after all threads are done):
pool_pkg.destroy(&p)
```

Rules:
- A message is either in the pool OR in a mailbox. Never both.
- Call destroy only after all threads have stopped using the pool.
- put() on a full pool frees the message instead of returning it.

---

## 11. MASTER pattern (pool + mailbox, coordinated shutdown)

One struct owns the pool and the mailbox. One shutdown call handles everything.

Key rule: drain the mailbox BEFORE destroying the pool.
If you destroy the pool first, the messages still in the mailbox become dangling pointers.

```odin
import pool_pkg "path/to/matryoshka/pool"

Master :: struct {
    pool:  pool_pkg.Pool(Msg),
    inbox: mbox.Mailbox(Msg),
}

master_init :: proc(m: ^Master) -> bool {
    return pool_pkg.init(&m.pool, initial_msgs = 8, max_msgs = 64)
}

master_shutdown :: proc(m: ^Master) {
    // 1. Close inbox. Get back any undelivered messages.
    remaining, _ := mbox.close(&m.inbox)

    // 2. Return them to pool — not free, pool owns them.
    for node := list.pop_front(&remaining); node != nil; node = list.pop_front(&remaining) {
        msg_opt: Maybe(^Msg) = container_of(node, Msg, "node")
        pool_pkg.put(&m.pool, &msg_opt)
    }

    // 3. Now safe to destroy pool.
    pool_pkg.destroy(&m.pool)
}
```

See `examples/master.odin` for a working version of this pattern.
