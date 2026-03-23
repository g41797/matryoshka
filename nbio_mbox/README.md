# nbio_mbox

Non-blocking mailbox for nbio event loops.

Wraps `loop_mbox.Mbox` with a wakeup mechanism that signals the nbio event loop
when a message is sent from another thread.

## Wake mechanisms

| Kind | How it works | Notes |
|------|-------------|-------|
| `.UDP` (default) | Sender writes 1 byte to a loopback UDP socket; nbio wakes on receipt | No queue limit |
| `.Timeout` | Zero-duration nbio timeout; CAS flag prevents queue overflow | Works on all platforms |

## Requirements

Your message struct must have a field named `node` of type `list.Node`:

```odin
import list "core:container/intrusive/list"

Msg :: struct {
    node: list.Node,
    data: int,
}
```

## Quick start

```odin
import nbio_mbox "path/to/matryoshka/nbio_mbox"
import loop_mbox  "path/to/matryoshka/loop_mbox"

// event-loop thread:
loop := nbio.current_thread_event_loop()
m, err := nbio_mbox.init_nbio_mbox(Msg, loop) // uses .UDP by default
defer {
    loop_mbox.close(m)
    loop_mbox.destroy(m)
}

// sender thread (any thread):
loop_mbox.send(m, msg)

// event-loop thread — drain in the tick loop:
for {
    nbio.tick(timeout)
    batch := loop_mbox.try_receive_batch(m)
    for node := list.pop_front(&batch); node != nil; node = list.pop_front(&batch) {
        msg := (^Msg)(node)
        // handle msg — free or return to pool
    }
}
```

## Thread model

| Operation | Thread |
|-----------|--------|
| `init_nbio_mbox` | any thread |
| `loop_mbox.send` | any thread |
| `loop_mbox.try_receive_batch` | event-loop thread only |
| `loop_mbox.close` | event-loop thread only |
| `loop_mbox.destroy` | event-loop thread (after close) |

"Event-loop thread" is the single thread calling `nbio.tick` for the given loop.

## Errors

| Error | Meaning |
|-------|---------|
| `.None` | Success |
| `.Invalid_Loop` | `loop` argument was `nil` |
| `.Keepalive_Failed` | `.Timeout` wakeuper allocation or mbox allocation failed |
| `.Socket_Failed` | `.UDP` socket creation or bind failed |
