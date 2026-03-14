// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

// try_mbox: MPSC queue based mailbox for event loops and worker loops.
//
// The consumer calls try_receive — no blocking, no mutex on the receive path.
// Multiple producers call send concurrently. One consumer calls try_receive.
//
// Not copyable after init. Use init to allocate on the heap.
// WakeUper is optional. Zero value = no notification on send.
//
// Stall: try_receive may return (nil, false) while length > 0.
// This is a property of the Vyukov MPSC queue. Retry on the next call.
//
// Thread model:
//   init        : any thread
//   send        : any thread (multiple producers, MPSC safe)
//   try_receive : consumer thread only — MPSC single-consumer rule
//   close       : consumer thread only — drains with mpsc.pop (single-consumer);
//                 must be called after all senders have stopped (threads joined)
//   destroy     : any thread after close (no concurrent access remains)
package try_mbox
