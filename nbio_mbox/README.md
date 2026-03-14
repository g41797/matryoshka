# nbio_mbox

Non-blocking mailbox for nbio event loops.

Wraps `try_mbox.Mbox` with a wakeup mechanism that signals the nbio event loop
when a message is sent from another thread.

## Wake mechanisms

| Kind | How it works | Notes |
|------|-------------|-------|
| `.UDP` (default) | Sender writes 1 byte to a loopback UDP socket; nbio wakes on receipt | Stable on Linux, macOS, Windows |
| `.Timeout` | Zero-duration nbio timeout; CAS flag prevents queue overflow | 128-slot cross-thread queue limit |

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
import nbio_mbox "path/to/odin-mbox/nbio_mbox"
import try_mbox  "path/to/odin-mbox/try_mbox"

// event-loop thread:
loop := nbio.current_thread_event_loop()
m, err := nbio_mbox.init_nbio_mbox(Msg, loop) // uses .UDP by default
defer {
    try_mbox.close(m)
    try_mbox.destroy(m)
}

// sender thread (any thread):
try_mbox.send(m, msg)

// event-loop thread — drain in the tick loop:
for {
    nbio.tick(timeout)
    for {
        msg, ok := try_mbox.try_receive(m)
        if !ok { break }
        // handle msg
    }
}
```

## Thread model

| Operation | Thread |
|-----------|--------|
| `init_nbio_mbox` | any thread |
| `try_mbox.send` | any thread |
| `try_mbox.try_receive` | event-loop thread only |
| `try_mbox.close` | event-loop thread only |
| `try_mbox.destroy` | event-loop thread (after close) |

"Event-loop thread" is the single thread calling `nbio.tick` for the given loop.

## Errors

| Error | Meaning |
|-------|---------|
| `.None` | Success |
| `.Invalid_Loop` | `loop` argument was `nil` |
| `.Keepalive_Failed` | `.Timeout` wakeuper allocation or mbox allocation failed |
| `.Socket_Failed` | `.UDP` socket creation or bind failed |
