# Migration Report - Unified Matryoshka API

This report details the changes made to the Matryoshka documentation to align with the unified API model (Layer 4).

## Overview of Changes

The Matryoshka library has transitioned to a model where infrastructure (Mailbox, Pool) are first-class items (`PolyNode`). They are now accessed via handles (`distinct ^PolyNode`) and follow a unified lifecycle.

## API Changes

### 1. Types
- `Mailbox`: Changed from a struct to `distinct ^PolyNode`.
- `Pool`: Changed from a struct to `distinct ^PolyNode`.

### 2. Creation & Disposal
- Replaced `mbox_init` and `mbox_destroy` with `mbox_new(alloc)` and `matryoshka_dispose(m)`.
- Replaced manual `Pool` struct initialization with `pool_new(alloc)` and `matryoshka_dispose(m)`.
- Unified teardown procedure: `matryoshka_dispose` now handles all infrastructure disposal. It requires the item to be **closed** first.

### 3. Procedure Signatures
- Updated all `mbox_*` procedures to take `Mailbox` instead of `^Mailbox`.
- Updated all `pool_*` procedures to take `Pool` instead of `^Pool`.
- Removed unnecessary `&` (address-of) operators from calls to these procedures in all documentation examples.

### 4. ID Rules
- Explicitly documented the ID range convention:
  - `id > 0`: User Data.
  - `id < 0`: Infrastructure.
  - `id == 0`: Invalid.
- Updated `PoolHooks` rule: `ids` registration array must now contain only positive values (`all > 0`).

## Document Updates

- **Design Hub (`design_hub.md`)**: Added Layer 4 (Meta) to the layer table and documentation list.
- **Layer 2 & 3 Quick References**: Updated types, signatures, and lifecycle procedures.
- **Layer 2 & 3 Deep Dives**: Updated all code examples and Master lifecycle patterns to use handles and unified disposal.
- **Layer 4 Quick Reference & Deep Dive**: Updated `dispose` to `matryoshka_dispose` and ensured consistency with the unified handle model.
- **Advice Catalog**: Updated tags and descriptions to reflect `matryoshka_dispose` and handle-based signatures.

## Fixed Contradictions
- Resolved inconsistencies between early layer documentation and the new Layer 4 "Meta" model.
- Ensured all examples in Layers 1-3 are forward-compatible with the Layer 4 architecture.

---
Report generated on Friday, 27 March 2026.
