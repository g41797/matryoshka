// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

/*
Package matryoshka is an inter-thread communication library for Odin.

Foundation:
  - PolyNode: intrusive node embedded at offset 0 in every item.
  - MayItem (alias for Maybe(^PolyNode)): ownership handle used at every API boundary.

Services:
  - Mailbox: moves items between threads with blocking receive.
  - Pool: reusable item storage with pluggable lifecycle hooks.
*/
package matryoshka
