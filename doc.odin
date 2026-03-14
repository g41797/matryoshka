/*
Package mbox is an inter-thread communication library for Odin.

Sub-packages:

  mbox/       — Mailbox($T): blocking worker-thread mailbox (condition variable)
  nbio_mbox/  — init_nbio_mbox: non-blocking nbio event-loop mailbox (UDP or timeout wakeup)
  try_mbox/   — Mbox($T): non-blocking MPSC mailbox (used by nbio_mbox internally)
  mpsc/       — Lock-free multi-producer single-consumer queue
  wakeup/     — WakeUper interface + semaphore-backed implementation
  pool/       — Object pool with optional blocking get and reset hook

All types use intrusive linking: your message struct must have a field named "node"
of type list.Node from core:container/intrusive/list.
*/
package mbox
