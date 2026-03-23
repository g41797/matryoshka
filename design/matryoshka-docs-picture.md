---

# 0. WHOLE PICTURE (always keep this in mind)

## Site structure (final target)

```
matryoshka/
  docs_site/
    docs/
      index.md

      concepts/
      components/
      guides/
      idioms/

      api/            # generated (read-only)

    mkdocs.yml
    build.sh
```

## Navigation model

```
Concepts  → how to think
Idioms    → how to apply thinking
Components→ building blocks
Guides    → how to assemble systems
API       → reference only
```

## Local workflow

```
edit structure → preview (mkdocs serve)
→ generate odin docs → rebuild
→ iterate
```

---

# 1. MASTER PLAN (AI-DRIVEN, STAGED)

Each stage:

* executed by ONE AI
* validated manually
* optionally reviewed by another AI

---

## STAGE 1 — Skeleton creation (Claude Code)

**Goal:** create structure + empty md files + mkdocs.yml

### Input to Claude:

> Create mkdocs project structure for matryoshka with folders:
> concepts, idioms, components, guides, api
> Each .md should contain placeholder instructions only (no real content)

### Output expected:

* folders created
* all md files exist
* mkdocs.yml valid

---

### CHECKPOINT 1

Run:

```bash
mkdocs serve
```

You should see:

* navigation works
* empty pages visible
* no API yet

---

### Optional review (Gemini CLI)

Ask:

> Does this navigation reflect a concurrency toolkit (not a library)?

---

## STAGE 2 — Structural refinement (Gemini CLI)

**Goal:** validate architecture, not content

### Input:

* mkdocs.yml
* folder structure

### Ask Gemini:

> Identify structural problems or missing conceptual layers

### Expected output:

* suggestions like:

  * missing “ownership”
  * missing “message lifecycle”
  * etc.

---

### CHECKPOINT 2

Apply only:

* renames
* folder moves
* no content writing yet

---

## STAGE 3 — Odin docs integration (Claude Code)

**Goal:** automate API generation

### Input:

> Add build script that generates odin docs into docs/api

---

### Expected:

`build.sh`:

```bash
#!/usr/bin/env bash

set -e

# clean api
rm -rf docs/api
mkdir -p docs/api

# generate odin docs (adjust path if needed)
odin doc ../src -out docs/api

# build site
mkdocs build
```

---

### CHECKPOINT 3

Run:

```bash
./build.sh
mkdocs serve
```

Verify:

* `/api` exists
* navigation includes API
* no manual copying needed

---

## STAGE 4 — Page intent definition (Claude Code)

**Goal:** define WHAT each page should contain

NOT content — only structure.

---

### Example instruction per file:

Instead of writing docs, Claude writes:

```md
# Mailbox

## Purpose
Explain what mailbox is in matryoshka

## When to use
Describe scenarios

## Guarantees
List concurrency guarantees

## Example
Minimal pseudo example

## Relations
How it interacts with pool, mpsc, loop
```

---

### CHECKPOINT 4

You review:

* is anything missing?
* does it match your mental model?

---

## STAGE 5 — Cross-review (Gemini CLI)

Ask:

> Are these page responsibilities overlapping or unclear?

Goal:

* eliminate duplication
* sharpen boundaries

---

## STAGE 6 — Iterative filling (later)

Only now you start writing real content.

---

# 2. FILE STRUCTURE (CREATE THIS)

```text
docs_site/
  docs/
    index.md

    concepts/
      mental_model.md
      ownership.md
      message_passing.md

    idioms/
      pipelines.md
      event_loop.md
      worker_pool.md

    components/
      mailbox.md
      mpsc.md
      pool.md
      loop.md
      wakeuper.md

    guides/
      getting_started.md
      building_pipeline.md
      event_loop.md

    api/
      index.md   # placeholder

  mkdocs.yml
  build.sh
```

---

# 3. mkdocs.yml (COPY)

```yaml
site_name: matryoshka
site_description: Message-driven concurrency toolkit for Odin

theme:
  name: material

nav:
  - Home: index.md

  - Concepts:
      - Mental Model: concepts/mental_model.md
      - Ownership: concepts/ownership.md
      - Message Passing: concepts/message_passing.md

  - Idioms:
      - Pipelines: idioms/pipelines.md
      - Event Loop: idioms/event_loop.md
      - Worker Pool: idioms/worker_pool.md

  - Components:
      - Mailbox: components/mailbox.md
      - MPSC Queue: components/mpsc.md
      - Pool: components/pool.md
      - Loop Mailbox: components/loop.md
      - Wakeuper: components/wakeuper.md

  - Guides:
      - Getting Started: guides/getting_started.md
      - Building Pipeline: guides/building_pipeline.md
      - Event Loop Guide: guides/event_loop.md

  - API:
      - Overview: api/index.md
```

---

# 4. STARTER FILES (IMPORTANT — COPY AS IS)

## index.md

```md
# matryoshka

Message-driven concurrency toolkit for Odin.

## What is this

This project provides building blocks for constructing concurrent systems:
- message passing
- queues
- pools
- event loops

## Structure of documentation

- Concepts — how to think
- Idioms — how to apply
- Components — primitives
- Guides — how to build systems
- API — reference

## Status

This documentation is under construction.
```

---

## concepts/mental_model.md

```md
# Mental Model

## Purpose
Explain the core philosophy of matryoshka.

## Must cover
- message-driven design
- ownership transfer
- avoidance of shared mutable state
- system composition

## Output
Reader should understand HOW to think, not HOW to code.
```

---

## components/mailbox.md

```md
# Mailbox

## Purpose
Define mailbox as core communication primitive.

## Must cover
- MPMC behavior
- ownership transfer
- async communication

## When to use
- thread-to-thread messaging
- actor-like patterns

## Relations
- used with pool
- interacts with loop
```

---

## idioms/pipelines.md

```md
# Pipelines

## Purpose
Describe pipeline pattern using mpsc and mailbox.

## Must cover
- stages
- flow of ownership
- flow control considerations

## Output
Reader can design pipeline system.
```

---

## guides/getting_started.md

```md
# Getting Started

## Purpose
Show minimal working system.

## Must include
- mailbox
- one producer
- one consumer

## Goal
User runs something quickly.
```

---

## api/index.md

```md
# API

This section contains generated Odin documentation.

Do not edit manually.
```

---

# 5. build.sh

```bash
#!/usr/bin/env bash
set -e

echo "Generating Odin docs..."
rm -rf docs/api
mkdir -p docs/api

# adjust path if needed
odin doc ../src -out docs/api || echo "Odin doc generation skipped"

echo "Building mkdocs..."
mkdocs build

echo "Done"
```

---

# 6. HOW TO USE AI PER STAGE

## Claude Code

Use for:

* file creation
* restructuring
* rewriting markdown structure

## Gemini CLI

Use for:

* critique
* gap detection
* alternative structures

---

# 7. RESUME STRATEGY (IMPORTANT)

At any point you can:

1. Stop
2. Commit
3. Later resume with:

> “Here is my current mkdocs structure — continue from Stage X”

---

# 8. KEY RULE (don’t break this)

During skeleton phase:

> ❌ No real content
> ✅ Only intent and structure

---

# FINAL THOUGHT

You’re building:

> **A thinking framework disguised as documentation**

So structure first is not just correct — it’s essential.

---

If next step you want, I can:

* generate prompts for Claude/Gemini per stage (copy-paste ready)
* or refine structure specifically for your current matryoshka repo content

Just tell me.
