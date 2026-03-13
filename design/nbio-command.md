# nbio Commands

### Document Rules (MUST)
- Simple English. Not everyone speaks English as first language.
- No smart AI words. Write like a human.
- No flowery or pathetic language.
- Short sentences.
- Use bullet lists. Replace long sentences with bullets.
- One idea per sentence.
- Be human.

---
## The nbio Team Sees the Light
- The nbio developers already know some people hate callbacks.
- There is a big discussion on the Odin forum about "Callback Hell".
- Some users want things to feel like "Go" with synchronous code.
- Without a heavy runtime, the best choice is a **Result Queue**.
- They made an example called `no-callbacks`.
- It uses a single, simple callback for everything.
...

- It calls `nbio.detach(op)` to take ownership of the data.
- It pushes the finished operation into a queue.
- This handles the **Inbound** results (I/O to you).
- Our proposal handles the **Outbound** commands (You to I/O).
- Together, they form a complete loop.

---

## Who is Who

### The Engine
- This is your code on the I/O thread.
- It runs a loop.
- It calls `nbio.tick()`.
- It owns the data.

### The Callback
- This is the function nbio calls when I/O is done.
- It can be a simple user function.
- Or it can be part of the Engine.
- It can just detach the operation and put it in a queue.

### The User
- This is code on other threads.
- It wants the Engine to do work.

---

## Two Kinds of Users

### 1. The Regular User (Callback Lovers)
- Uses `nbio` for simple tasks.
- Likes **Callbacks** because they are standard.
- Logic is short.
- Does not need a complex state machine.

### 2. The Engine User (Queue Lovers)
- Uses `nbio` as a building block for a large system.
- Needs **Queues** for safe, atomic commands.
- Manages complex data without locks.
- Wants a clean loop (tick -> process commands -> repeat).

### Can they live together?
- Yes!
- The Engine uses **Commands** to start a task.
- The Engine uses **Callbacks** to handle the raw I/O.
- The Callbacks send **Commands** back to the Engine.
- This prevents "callback hell" but keeps the speed of nbio.

---

## Why the Engine Way is Safe
- The Engine runs on a single thread.
- It can update its own data without locks.
- No other thread touches its data.
- This is fast and safe.

---

## Code Skeleton

```odin
// Engine (I/O Thread)
for !done {
    // 1. Do I/O work
    nbio.tick()

    // 2. Check for I/O Results (The Official Way)
    for op in try_pop(finished_io_queue) {
        handle_io_result(op)
        nbio.reattach(op) // Give it back to nbio
    }

    // 3. Check for User Commands (Our Way)
    for cmd_ptr, ok := nbio.try_recv_command(); ok; cmd_ptr, ok = nbio.try_recv_command() {
        cmd := (^My_Cmd)(cmd_ptr)
        handle_engine_logic(cmd)
    }
}

// The Universal Callback
on_any_io_done :: proc(op: ^nbio.Operation) {
    nbio.detach(op)
    push_to_finished_queue(op)
    nbio.post_command(op.l, .Wake_Up)
}
```

---
## Two Ways to Chain Work

### Variant A: Direct in Callback
- **Engine**: Starts a `dial`.
- **Callback**: If dial is OK, the callback starts a `send`.
- This is fast.
- But it can lead to "callback hell" if you have many steps.

### Variant B: Back to the Engine (The Clean Way)
- **Engine**: Starts a `dial`.
- **Callback**: If dial is OK, the callback sends a "Dial Done" command to the Engine.
- **Engine**: Picks up the command after `tick()`.
- **Engine**: Starts the `send`.
- This is much cleaner.
- All state changes happen in one place (the Engine).
- It is easy to debug.

---

## Real Example: Tofu Connect
...

- **User**: Wants to talk to a server at `127.0.0.1:7099`.
- **User**: Makes a `Hello_Msg`.
- **User**: It has the server address and some extra user data.
- **User**: Sends the message to the Engine.
- **Engine**: Sees the message after `tick()`.
- **Engine**: Reads the address and creates a socket.
- **Engine**: It starts a `dial` operation.
- **Engine (Callback)**: If the dial works, it starts a `send` for the message.
- **Engine (Callback)**: If it fails, it sets an error (like `connect_failed`).
- **Engine (Callback)**: It posts a "Done" command back to the Engine loop.
- **Engine**: After the next `tick()`, it sees the "Done" command.
- **Engine**: It updates its list of active connections (no locks!).
- **Engine**: It pushes the message to the User's mailbox.

---

## To Change or Not to Change?
- `nbio.Operation` is already public.
- It has a field called `user_data`.
- This is an array of pointers.
- You can put a pointer to your own info there.
- You do not **need** to change the `Operation` struct.
- Changing the core library is hard for 3rd parties.

## The Better Way: Your Own Command Struct
- Create your own `My_Cmd` struct.
- It can be any size.
- It can have any data you need.
- When you start I/O (like `dial`), do this:
  - `op.user_data[0] = &my_command`.
- The callback then does this:
  - `cmd := (^My_Cmd)(op.user_data[0])`.
- This works with nbio today.

---

## Proposed API
- `nbio.post_command(loop, data)`: Send a pointer to the loop.
- `nbio.try_recv_command()`: Get a pointer from the queue.
- Both are atomic.
---

## The Lost Wake-up Problem

### The Claim
Set up nbio before sending signals. 
The loop must be listening to catch signals for external queues.

### The AnalysisA "lost wake-up" is a race condition.
It happens when a signal is sent but no one is ready.
This matters for Loop_Mailbox because it is an external queue.
nbio does not check external queues before it sleeps.

#### 1. Lazy Setup (macOS/BSD/Linux)
- nbio might wait to tell the kernel about the "Wake-up Event".
- It happens during the first tick.
- If you call wake_up() before that, the signal might be lost.

#### 2. Windows Optimization
- nbio only sends a signal if it thinks the loop is .Sleeping.
- This saves time for internal tasks.
- But if a message arrives while nbio is starting to sleep, the signal is dropped.
- The loop thread then sleeps for the full timeout.

### Summary
nbio wake-up is for internal tasks. 
It misses our external Loop_Mailbox queue. 

### The Solution: no-op
A no-op makes wake-up reliable.

#### Internal and External Queues
- nbio has its own internal queue.
- It checks this queue right before it sleeps.
- Loop_Mailbox is an external queue.
- nbio checks its own queue before sleep. It misses our queue. 
- We add a no-op to its queue. Now nbio sees our messages too.

#### The Pattern
1. Put message in Loop_Mailbox.
2. Add a no-op task to nbio using nbio.timeout(0, noop, loop).
3. nbio.exec (called by timeout) will call wake_up.

This uses nbio race-protection for our queue. 
odin-mbox does this in send_to_loop.
Users do not need manual sync.
Handle commands and I/O on one thread.

### Keep-alive Timer
nbio.tick() only blocks if the loop has internal work (sockets, timers).
Loop_Mailbox is an external queue, so nbio doesn't know it should block.
init_loop_mailbox() creates a hidden keep-alive timer.
This timer makes nbio.tick() block in the kernel instead of returning immediately.
close_loop() automatically stops and removes this timer.
---

## References
