# mbox

Blocking inter-thread mailbox for Odin.

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
import mbox "path/to/odin-mbox/mbox"

mb: mbox.Mailbox(Msg)

// sender thread:
msg := new(Msg)
msg.data = 42
mbox.send(&mb, msg)

// receiver thread (blocks until message arrives):
got, err := mbox.wait_receive(&mb)
if err == .None {
    // use got.data
    free(got)
}
```

## Thread model

| Operation | Thread |
|-----------|--------|
| `send` | any thread |
| `wait_receive` | any thread (blocks) |
| `interrupt` | any thread |
| `close` | any thread |

## Allocation rules

- Caller allocates messages before `send`.
- `wait_receive` returns the pointer — caller frees it.
- `close` returns undelivered messages as a `list.List` — caller frees each one.
- Zero copies: the pointer is passed as-is through the mailbox.

## Errors

| Error | Meaning |
|-------|---------|
| `.None` | Message received |
| `.Timeout` | Timed out (no message) |
| `.Closed` | Mailbox was closed |
| `.Interrupted` | `interrupt()` was called |

## Reuse

After `close`, reset the mailbox with `mb = {}` once all waiters have exited.
