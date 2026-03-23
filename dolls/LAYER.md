# dolls/LAYER.md — spiral layer state

> Resume anchor for layer implementation sessions.
> Start every session by reading this file.
> Update it after every  session.
> Spec source: `design/compose/design.md`

---

## Spiral spec

| Layer | What you have | What you don't need yet |
|-------|--------------|------------------------|
| 1 | `PolyNode` + `Maybe` | everything else |
| 2 | + hooks (`factory`, `dispose`) | pool, mailbox |
| 3 | + simple pool (wrapper around hooks) | extended pool, mailbox |
| 4 | + extended pool (free-list, flow control) | mailbox |
| 5 | + mailbox | — full itc |

**Rule:** move to the next doll because you need it — not because it is there.

---

## Layer status

| Layer | Status |
|-------|--------|
| 1 | complete |
| 2 | in progress |
| 3 | not started |
| 4 | not started |
| 5 | not started |

---

## How to create Layer N+1 from Layer N

> Read this before starting any new layer session.

### Mechanics

1. **Copy the previous doll:**
   ```sh
   cd dolls && ./create_layer.sh
   ```
   Creates `dollN+1/` from `dollN/`, updates `matryoshka.code-workspace`.
   The copy is complete — all packages, build scripts, `.vscode/tasks.json` are included.

2. **Create empty stub files** for each new package this layer introduces.
   Use zero-length files — do not write content yet (user fills them):
   ```sh
   mkdir -p dolls/dollN+1/<pkg>/
   touch dolls/dollN+1/<pkg>/doc.odin
   touch dolls/dollN+1/<pkg>/impl.odin
   mkdir -p dolls/dollN+1/examples/<pkg>/
   touch dolls/dollN+1/examples/<pkg>/doc.odin
   touch dolls/dollN+1/examples/<pkg>/<example>.odin
   mkdir -p dolls/dollN+1/tests/<pkg>/
   touch dolls/dollN+1/tests/<pkg>/<test>.odin
   ```

3. **Update `build_and_test.sh` and `build_and_test_debug.sh`:**
   Each script has three multi-line arrays at the top. Add new paths to the relevant arrays:
   ```bash
   BUILDS=(          # odin build ./<path>/  — root libs + examples/
       item
       hooks
       <new-pkg>           # ← add
       examples/item
       examples/hooks
       examples/<new-pkg>  # ← add
   )
   TESTS=(           # odin test ./<path>/  — root libs with embedded tests + tests/
       item
       tests/item
       tests/hooks
       tests/<new-pkg>     # ← add
   )
   DOCS=(            # odin doc ./<path>/   — same as BUILDS typically
       item
       hooks
       <new-pkg>           # ← add
       examples/item
       examples/hooks
       examples/<new-pkg>  # ← add
   )
   ```
   The loop body does not change. Update the banner string from `dollN` to `dollN+1`.
   Zero-length stubs are automatically skipped (`-size +0c` guard is in the loop body).

4. **Update `.vscode/tasks.json`:**
   Add a `{ "label": "tests/<pkg>/", "value": "tests/<pkg>" }` entry to the pickString options for each new test package.

5. **Update `dolls/LAYER.md`:**
   - Mark layer N+1 status → `in progress`
   - Add a Layer N+1 section (packages, key types, API, contracts, build command)

### Spec change workflow

If the new layer requires changes to `design/compose/design.md` or `design/compose/pool_redesign.md`:
- Apply the same change to **both files** — they must stay in sync.
- Common changes: new struct fields, renamed procs, updated signatures, new contracts.
- Update the Master pattern example in both docs if the init/teardown sequence changes.
- If a type moves from one struct to another (e.g., `ids` moved into `PoolHooks`), update all call sites shown in examples within the docs.
- Add a note for any Odin operator/stdlib limitation that affects the new API (e.g., `in` operator does not work on `[dynamic]int` — use `slice.contains`).

### What each layer section must contain

Each `## Layer N — ...` section should document:
- Path (`dolls/dollN/`)
- What it adds (one sentence)
- Package table (package name, path, contents)
- Key types (code block)
- API (code block)
- Key contracts (bullet list — enough for an implementor)
- Build command

---

## Layer 1 — complete

**Path:** `dolls/doll1/`

**Note:** doll1 contains `hooks` (`ctor`, `dtor` proc fields only).
Per spec, hooks belong at layer2.
This is accepted — doll1 is a slightly richer doll1, all tests pass.

### Packages

| Package | Path | Import path (from inside doll1) | Contents |
|---------|------|----------------------------------|----------|
| item | `item/` | `"./item"` (local) | `PolyNode`, `Maybe` — foundation types |
| hooks | `hooks/` | `"../item"` (item is its dependency) | `Ctor_Dtor` struct — ctor, dtor proc fields |
| examples/item | `examples/item/` | — | `Event`, `Sensor`, `ItemId`; `example_produce_consume`, `example_ownership` |
| examples/hooks | `examples/hooks/` | — | `item_factory`, `item_dispose`, `make_flow_policy` |
| tests/item | `tests/item/` | — | integration tests for examples/item |
| tests/hooks | `tests/hooks/` | — | 6 tests: factory_event, factory_sensor, factory_unknown, dispose, roundtrip, dispose_nil_handle |

### Key types

```odin
// package item
PolyNode :: struct {
    using node: list.Node, // intrusive link — .prev, .next
    id:         int,       // type discriminator, must be != 0
}

// package hooks
Ctor_Dtor :: struct {
    ctor: proc(id: int) -> Maybe(^item.PolyNode),
    dtor: proc(m: ^Maybe(^item.PolyNode)),
}
```

Note: doll1 `Ctor_Dtor` has `ctor` and `dtor` only — create and destroy, no pool logic.
`PoolHooks` (layer3+) adds `ctx rawptr`, `in_pool_count int`, merges create/reuse into `on_get`.

### Build

```sh
cd dolls/doll1 && ./build_and_test.sh
```

Runs 5 opt levels (`none minimal size speed aggressive`) + doc smoke test.
All pass.

---

---

## Layer 2 — in progress

**Path:** `dolls/doll2/`

**What it adds:** Simple Pool — thread-safe free-list for `^PolyNode` items with pluggable lifecycle hooks.

### How this doll was created

1. `cd dolls && ./create_layer.sh` — copies doll1 → doll2, updates workspace.
2. Created zero-length stub files:
   - `pool/doc.odin`, `pool/pool.odin`
   - `examples/pool/doc.odin`, `examples/pool/types.odin`, `examples/pool/master.odin`
   - `tests/pool/pool_test.odin`, `tests/pool/edge_test.odin`
3. Updated `build_and_test.sh` and `build_and_test_debug.sh`: added guarded blocks for `pool`, `examples/pool`, `tests/pool` using `-size +0c` guard. Updated banner to doll2.
4. Updated `.vscode/tasks.json`: added `tests/pool/` to pickString options.

### Packages

| Package | Path | Contents |
|---------|------|----------|
| item | `item/` | `PolyNode`, `Maybe` — copied from doll1, unchanged |
| hooks | `hooks/` | `Ctor_Dtor` — copied from doll1, unchanged |
| pool | `pool/` | `Pool`, `PoolHooks`, `pool_init/close/get/put/get_wait` |
| examples/item | `examples/item/` | copied from doll1, unchanged |
| examples/hooks | `examples/hooks/` | copied from doll1, unchanged |
| examples/pool | `examples/pool/` | `Master` pattern: `newMaster`, `freeMaster`, `on_get`, `on_put` |
| tests/item | `tests/item/` | copied from doll1, unchanged |
| tests/hooks | `tests/hooks/` | copied from doll1, unchanged |
| tests/pool | `tests/pool/` | unit tests + concurrency tests |

### Key design change vs spec

`PoolHooks` gains `ids: [dynamic]int` (user-owned). `pool_init` no longer takes `ids` param.
`pool_put` validates with `slice.contains(p.valid_ids, id)` — not Odin's `in` operator.

### Key types

```odin
PoolHooks :: struct {
    ctx:    rawptr,
    ids:    [dynamic]int,   // user populates before pool_init; user deletes in freeMaster
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}

Pool :: struct {
    hooks:     ^PoolHooks,
    valid_ids: []int,       // slice view of hooks.ids — valid after pool_close
    list:      list.List,   // flat free-list, all ids mixed
    counts:    map[int]int, // per-id idle count; Pool allocates this in pool_init
    mutex:     sync.Mutex,
    cond:      sync.Cond,
    state:     Pool_State,
}

Pool_State      :: enum { Uninit, Active, Closed }
Pool_Get_Mode   :: enum { Available_Or_New, New_Only, Available_Only }
Pool_Get_Result :: enum { Ok, Not_Available, Not_Created, Closed }
```

### API

```odin
pool_init     :: proc(p: ^Pool, hooks: ^PoolHooks)
pool_close    :: proc(p: ^Pool) -> (list.List, ^PoolHooks)
pool_get      :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, out: ^Maybe(^PolyNode)) -> Pool_Get_Result
pool_put      :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
pool_get_wait :: proc(p: ^Pool, id: int, out: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

### Master pattern (examples/pool)

```odin
Master :: struct { p: Pool, hooks: PoolHooks, alloc: mem.Allocator, ... }

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.hooks = PoolHooks{ ctx = m, on_get = master_on_get, on_put = master_on_put }
    append(&m.hooks.ids, int(ItemId.Chunk))
    append(&m.hooks.ids, int(ItemId.Token))
    pool_init(&m.p, &m.hooks)
    return m
}

freeMaster :: proc(m: ^Master) {
    nodes, _ := pool_close(&m.p)
    for { raw := list.pop_front(&nodes); if raw == nil { break }; node_dispose((^PolyNode)(raw)) }
    delete(m.hooks.ids)
    alloc := m.alloc
    free(m, alloc)
}
```

### Contracts (for implementor)

**pool_init:** assert hooks non-nil, both procs non-nil, len(ids)>0, all ids!=0. Set valid_ids=hooks.ids[:]. make(map[int]int). cond_init. state=Active.

**pool_get (Available_Or_New):** lock → scan list for id → pop+decrement count → unlock → call on_get outside lock. Miss: unlock → out^=nil → call on_get. on_get result: non-nil→Ok, nil→Not_Created.

**pool_put:** id==0→panic. !slice.contains→panic. Lock, read in_pool_count, unlock. Call on_put OUTSIDE lock. Lock: if m^ non-nil→push list, increment count, m^=nil, cond_signal. Closed+valid id: skip push, leave m^ non-nil (no panic).

**pool_close:** lock → Closed → capture list → cond_broadcast → capture hooks ptr, nil p.hooks → unlock → delete(p.counts) → return list,h.

**pool_get_wait:** Available_Only semantics + blocking. Never calls on_get. Woken by pool_put (cond_signal) or pool_close (cond_broadcast).

**Hooks always called outside mutex.** in_pool_count is a snapshot taken under lock then released.

### Build

```sh
cd dolls/doll2 && ./build_and_test.sh
```

---

## Conventions

- Every doll lives under `dolls/layerN/`.
- Each doll is a self-contained Odin workspace with its own `build_and_test.sh`.
- Packages import siblings via relative paths (e.g. `"../item"`).
- Update this file as part of every layer session — before ending the session.


---

# Plan: dolls/doll2 — Simple Pool (Layer 2)

## Context

The MPSC queue layer (formerly layer 2) was removed from LAYER.md. Pool is now layer 2 — "simple pool, wrapper around hooks". The current `pool_redesign.md` has a design flaw: `pool_init` takes `ids: []int` but Pool must not allocate — it can't copy and store ids internally. Fix: move `ids: [dynamic]int` into `PoolHooks` (user-owned). "check claim" = verify `pool_put` id validation still works with the new location.

---

## Design change: PoolHooks gains `ids`

**Updated struct** (apply to BOTH `design.md` and `pool_redesign.md`):
```odin
PoolHooks :: struct {
    ctx:    rawptr,
    ids:    [dynamic]int,   // user-owned; non-empty, all != 0
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}
```

**Updated `pool_init`:** `proc(p: ^Pool, hooks: ^PoolHooks)` — no `ids` param.

**`pool_put` claim check:** `slice.contains(p.valid_ids, ptr.id)` — Odin's `in` operator does not work on `[dynamic]int`. Pool stores `valid_ids: []int = hooks.ids[:]` (3-word slice header, no copy) for post-close use.

**`newMaster` pattern change:**
```odin
append(&m.hooks.ids, int(ItemId.Chunk))
append(&m.hooks.ids, int(ItemId.Token))
pool_init(&m.pool, &m.hooks)
// freeMaster: before free(m, alloc):
delete(m.hooks.ids)
```

---

## Step 1 — Run create_layer.sh

```sh
cd dolls && ./create_layer.sh
```

This creates `dolls/doll2/` as a full copy of `dolls/doll1/` and updates `matryoshka.code-workspace`. The copy includes: `item/`, `hooks/`, `examples/item/`, `examples/hooks/`, `tests/item/`, `tests/hooks/`, `build_and_test.sh`, `build_and_test_debug.sh`, `.vscode/tasks.json`.

---

## Step 2 — Create new empty files for pool

Create the following directories and **zero-length files** (user fills content later):

```
dolls/doll2/pool/
    doc.odin          ← zero-length
    pool.odin         ← zero-length  (Pool struct, PoolHooks, all pool_* procs)

dolls/doll2/examples/pool/
    doc.odin          ← zero-length
    types.odin        ← zero-length  (Chunk, Token, ItemId)
    master.odin       ← zero-length  (newMaster/freeMaster + on_get/on_put)

dolls/doll2/tests/pool/
    pool_test.odin    ← zero-length  (unit tests)
    edge_test.odin    ← zero-length  (concurrency tests)
```

---

## Step 3 — Update build_and_test.sh

Add three new guarded blocks after the existing hooks blocks, following the **identical pattern** used for `hooks` and `examples/hooks`. Use `-size +0c` in the find guard to skip zero-length files (so the script stays runnable while files are stubs):

**Block to add — pool lib:**
```bash
if [ -d "./pool" ] && [ -n "$(find ./pool -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
    echo "  build pool lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./pool/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./pool/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi
fi
```

**Block to add — examples/pool lib:**
```bash
if [ -d "./examples/pool" ] && [ -n "$(find ./examples/pool -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
    echo "  build examples/pool lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./examples/pool/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./examples/pool/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi
fi
```

**Block to add — tests/pool:**
```bash
if [ -d "./tests/pool" ] && [ -n "$(find ./tests/pool -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
    echo "  test tests/pool/..."
    if [ "${opt}" = "none" ]; then
        odin test ./tests/pool/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./tests/pool/ -vet -strict-style -disallow-do -o:"${opt}"
    fi
fi
```

**Doc smoke test section** — add:
```bash
if [ -d "./pool" ] && [ -n "$(find ./pool -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
    odin doc ./pool/
fi
if [ -d "./examples/pool" ] && [ -n "$(find ./examples/pool -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
    odin doc ./examples/pool/
fi
```

**Update banner:** change `"Starting doll1 local CI..."` → `"Starting doll2 local CI..."`.

---

## Step 4 — Update build_and_test_debug.sh

Same additions as Step 3 (debug script has identical structure, only `OPTS=(none)`).
Update banner to `"Starting doll2 local CI..."`.

---

## Step 5 — Update .vscode/tasks.json

Add `tests/pool` to the pickString options list:

```json
{ "label": "tests/pool/", "value": "tests/pool" }
```

Result:
```json
"options": [
    { "label": "tests/item/",  "value": "tests/item" },
    { "label": "tests/hooks/", "value": "tests/hooks" },
    { "label": "tests/pool/",  "value": "tests/pool" }
]
```

---

## Step 6 — Update design docs (keep in sync)

Apply identical changes to both files:
- `design/compose/pool_redesign.md`
- `design/compose/design.md`

Changes:
1. `PoolHooks` struct — add `ids: [dynamic]int` field
2. `pool_init` signature — remove `ids: []int` parameter
3. Master example — add `append(&m.hooks.ids, ...)` before `pool_init`; add `delete(m.hooks.ids)` in `freeMaster`
4. Add note: "`pool_put` id validation uses `slice.contains(hooks.ids[:], id)` — Odin's `in` does not work on `[dynamic]int`"

---

## Step 7 — Update dolls/LAYER.md

1. Add generic **"How to create Layer N+1 from Layer N"** section — place it **above all layer-specific sections**, before "Layer 1 — complete". Full workflow: mechanics + spec change guidance.
2. Mark layer 2 status → `in progress`
3. Add full **Layer 2** section
4. Append this plan file content at the end *(done)*

### Generic guide

```markdown
## How to create Layer N+1 from Layer N

> Read this before starting any new layer session.

### Mechanics

1. **Copy the previous doll:**
   ```sh
   cd dolls && ./create_layer.sh
   ```
   Creates `dollN+1/` from `dollN/`, updates `matryoshka.code-workspace`.
   The copy is complete — all packages, build scripts, `.vscode/tasks.json` are included.

2. **Create empty stub files** for each new package this layer introduces.
   Use zero-length files — do not write content yet (user fills them):
   ```sh
   mkdir -p dolls/dollN+1/<pkg>/
   touch dolls/dollN+1/<pkg>/doc.odin
   touch dolls/dollN+1/<pkg>/impl.odin
   mkdir -p dolls/dollN+1/examples/<pkg>/
   touch dolls/dollN+1/examples/<pkg>/doc.odin
   touch dolls/dollN+1/examples/<pkg>/<example>.odin
   mkdir -p dolls/dollN+1/tests/<pkg>/
   touch dolls/dollN+1/tests/<pkg>/<test>.odin
   ```

3. **Update `build_and_test.sh` and `build_and_test_debug.sh`:**
   Each script has three multi-line arrays at the top. Add new paths to the relevant arrays:
   ```bash
   BUILDS=(          # odin build ./<path>/  — root libs + examples/
       item
       hooks
       <new-pkg>           # ← add
       examples/item
       examples/hooks
       examples/<new-pkg>  # ← add
   )
   TESTS=(           # odin test ./<path>/  — root libs with embedded tests + tests/
       item
       tests/item
       tests/hooks
       tests/<new-pkg>     # ← add
   )
   DOCS=(            # odin doc ./<path>/   — same as BUILDS typically
       item
       hooks
       <new-pkg>           # ← add
       examples/item
       examples/hooks
       examples/<new-pkg>  # ← add
   )
   ```
   The loop body does not change. Update the banner string from `dollN` to `dollN+1`.
   Zero-length stubs are automatically skipped (`-size +0c` guard is in the loop body).

4. **Update `.vscode/tasks.json`:**
   Add a `{ "label": "tests/<pkg>/", "value": "tests/<pkg>" }` entry to the pickString options for each new test package.

5. **Update `dolls/LAYER.md`:**
   - Mark layer N+1 status → `in progress`
   - Add a Layer N+1 section (packages, key types, API, contracts, build command)

### Spec change workflow

If the new layer requires changes to `design/compose/design.md` or `design/compose/pool_redesign.md`:
- Apply the same change to **both files** — they must stay in sync.
- Common changes: new struct fields, renamed procs, updated signatures, new contracts.
- Update the Master pattern example in both docs if the init/teardown sequence changes.
- If a type moves from one struct to another (e.g., `ids` moved into `PoolHooks`), update all call sites shown in examples within the docs.
- Add a note for any Odin operator/stdlib limitation that affects the new API (e.g., `in` operator does not work on `[dynamic]int` — use `slice.contains`).

### What each layer section must contain

Each `## Layer N — ...` section should document:
- Path (`dolls/dollN/`)
- What it adds (one sentence)
- Package table (package name, path, contents)
- Key types (code block)
- API (code block)
- Key contracts (bullet list — enough for an implementor)
- Build command
```

### Layer 2 section

```markdown
## Layer 2 — in progress

**Path:** `dolls/doll2/`

**What it adds:** Simple Pool — thread-safe free-list for `^PolyNode` items with pluggable lifecycle hooks.

### How this doll was created

1. Run `cd dolls && ./create_layer.sh` — copies doll1 → doll2, updates workspace.
2. Create empty files for new packages (zero-length; user fills content):
   - `pool/doc.odin`, `pool/pool.odin`
   - `examples/pool/doc.odin`, `examples/pool/types.odin`, `examples/pool/master.odin`
   - `tests/pool/pool_test.odin`, `tests/pool/edge_test.odin`
3. Update `build_and_test.sh` and `build_and_test_debug.sh`: add guarded blocks for `pool`, `examples/pool`, `tests/pool` using `-size +0c` guard. Update banner to doll2.
4. Update `.vscode/tasks.json`: add `tests/pool/` to pickString options.

### Packages

| Package | Path | Contents |
|---------|------|----------|
| item | `item/` | `PolyNode`, `Maybe` — copied from doll1, unchanged |
| hooks | `hooks/` | `Ctor_Dtor` — copied from doll1, unchanged |
| pool | `pool/` | `Pool`, `PoolHooks`, `pool_init/close/get/put/get_wait` |
| examples/item | `examples/item/` | copied from doll1, unchanged |
| examples/hooks | `examples/hooks/` | copied from doll1, unchanged |
| examples/pool | `examples/pool/` | `Master` pattern: `newMaster`, `freeMaster`, `on_get`, `on_put` |
| tests/item | `tests/item/` | copied from doll1, unchanged |
| tests/hooks | `tests/hooks/` | copied from doll1, unchanged |
| tests/pool | `tests/pool/` | unit tests + concurrency tests |

### Key design change vs spec

`PoolHooks` gains `ids: [dynamic]int` (user-owned). `pool_init` no longer takes `ids` param.
`pool_put` validates with `slice.contains(p.valid_ids, id)` — not Odin's `in` operator.

### Key types

```odin
PoolHooks :: struct {
    ctx:    rawptr,
    ids:    [dynamic]int,   // user populates before pool_init; user deletes in freeMaster
    on_get: proc(ctx: rawptr, id: int, in_pool_count: int, m: ^Maybe(^PolyNode)),
    on_put: proc(ctx: rawptr, in_pool_count: int, m: ^Maybe(^PolyNode)),
}

Pool :: struct {
    hooks:     ^PoolHooks,
    valid_ids: []int,       // slice view of hooks.ids — valid after pool_close
    list:      list.List,   // flat free-list, all ids mixed
    counts:    map[int]int, // per-id idle count; Pool allocates this in pool_init
    mutex:     sync.Mutex,
    cond:      sync.Cond,
    state:     Pool_State,
}

Pool_State    :: enum { Uninit, Active, Closed }
Pool_Get_Mode :: enum { Available_Or_New, New_Only, Available_Only }
Pool_Get_Result :: enum { Ok, Not_Available, Not_Created, Closed }
```

### API

```odin
pool_init     :: proc(p: ^Pool, hooks: ^PoolHooks)
pool_close    :: proc(p: ^Pool) -> (list.List, ^PoolHooks)
pool_get      :: proc(p: ^Pool, id: int, mode: Pool_Get_Mode, out: ^Maybe(^PolyNode)) -> Pool_Get_Result
pool_put      :: proc(p: ^Pool, m: ^Maybe(^PolyNode))
pool_get_wait :: proc(p: ^Pool, id: int, out: ^Maybe(^PolyNode), timeout: time.Duration) -> Pool_Get_Result
```

### Master pattern (examples/pool)

```odin
Master :: struct { p: Pool, hooks: PoolHooks, alloc: mem.Allocator, ... }

newMaster :: proc(alloc: mem.Allocator) -> ^Master {
    m := new(Master, alloc)
    m.alloc = alloc
    m.hooks = PoolHooks{ ctx = m, on_get = master_on_get, on_put = master_on_put }
    append(&m.hooks.ids, int(ItemId.Chunk))
    append(&m.hooks.ids, int(ItemId.Token))
    pool_init(&m.p, &m.hooks)
    return m
}

freeMaster :: proc(m: ^Master) {
    nodes, _ := pool_close(&m.p)
    for { raw := list.pop_front(&nodes); if raw == nil { break }; node_dispose((^PolyNode)(raw)) }
    delete(m.hooks.ids)
    alloc := m.alloc
    free(m, alloc)
}
```

### Contracts (for implementor)

**pool_init:** assert hooks non-nil, both procs non-nil, len(ids)>0, all ids!=0. Set valid_ids=hooks.ids[:]. make(map[int]int). cond_init. state=Active.

**pool_get (Available_Or_New):** lock → scan list for id → pop+decrement count → unlock → call on_get outside lock. Miss: unlock → out^=nil → call on_get. on_get result: non-nil→Ok, nil→Not_Created.

**pool_put:** id==0→panic. !slice.contains→panic. Lock, read in_pool_count, unlock. Call on_put OUTSIDE lock. Lock: if m^ non-nil→push list, increment count, m^=nil, cond_signal. Closed+valid id: skip push, leave m^ non-nil (no panic).

**pool_close:** lock → Closed → capture list → cond_broadcast → capture hooks ptr, nil p.hooks → unlock → delete(p.counts) → return list,h.

**pool_get_wait:** Available_Only semantics + blocking. Never calls on_get. Woken by pool_put (cond_signal) or pool_close (cond_broadcast).

**Hooks always called outside mutex.** in_pool_count is a snapshot taken under lock then released.

### Build

```sh
cd dolls/doll2 && ./build_and_test.sh
```
```

---

## Verification

After all steps:
```sh
cd dolls/doll2 && ./build_and_test_debug.sh   # passes (pool files zero-length, skipped by -size +0c)
cd dolls/doll2 && ./build_and_test.sh          # same
```
Once user fills in pool source files:
```sh
cd dolls/doll2 && ./build_and_test.sh          # all 5 opt levels pass, pool included
```

<!--
## Layer 2 — planned

**What it adds:** A lock-free MPSC queue operating on `^PolyNode` directly.
Sole change from `mpsc/queue.odin`: replace `Queue($T)` (generic, requires `node: list.Node`)
with a non-generic `Queue` working on `^PolyNode`.

**Source:** Vyukov algorithm from `mpsc/queue.odin` — same algorithm, same properties.

**Why doll 2:**
- Simpler than pool + mailbox (no blocking, no pool, no lifecycle hooks needed)
- Usable for simple MT producer-consumer systems on its own
- Builds on doll1's `PolyNode` — fits the spiral type contract
- Foundation for `loop_mbox` (a future doll)

### API

| Proc | Signature | Notes |
|------|-----------|-------|
| `init` | `proc(q: ^Queue)` | Initializes stub, head, tail, len |
| `push` | `proc(q: ^Queue, msg: ^Maybe(^item.PolyNode)) -> bool` | nil msg^ → no-op, returns false. On success: msg^ = nil, returns true |
| `pop` | `proc(q: ^Queue) -> ^item.PolyNode` | Returns nil on empty OR transient stall — caller retries |
| `length` | `proc(q: ^Queue) -> int` | Approximate count |

**pop return style:** returns `^PolyNode` directly (not out-param).
Rationale: nil means "empty or transient stall — retry", not an error.
Caller wraps for lifecycle tracking when needed: `m: Maybe(^PolyNode) = pop(&q)`.

**Queue is NOT copyable after init** — stub address is embedded in head/tail.

```odin
// package mpsc  (dolls/layer2/mpsc/)
import item "../item"   // PolyNode from doll1

Queue :: struct {
    head: ^list.Node,
    tail: ^list.Node,
    stub: list.Node,
    len:  int,
}
```

### Directory layout

```
dolls/layer2/
├── item/              — copy from doll1/item/ (PolyNode dependency, doll self-contained)
├── mpsc/              — PolyNode-adapted queue (~same size as mpsc/queue.odin)
├── examples/
│   └── mpsc/          — MT example: N producers, 1 consumer, dispatch on PolyNode.id
├── tests/
│   └── mpsc/          — unit tests + concurrency stress test
└── build_and_test.sh
```

### Examples scope

`examples/mpsc/` shows:
- Concrete types embedding `PolyNode` at offset 0
- Multiple producer goroutines pushing typed items
- Single consumer dispatching on `id` with `switch`
- Ownership transfer via `push` / wrap in `Maybe` after `pop`

### Tests scope

`tests/mpsc/`:
- Unit: init, empty pop, push/pop single, FIFO order, stall retry
- Stress: N producers × M items, consumer drains all, verify count and FIFO

### Build

```sh
cd dolls/layer2 && ./build_and_test.sh
``` -->
