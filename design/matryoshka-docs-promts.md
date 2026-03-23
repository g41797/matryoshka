# matryoshka Documentation System — AI Execution Prompts

This file contains **copy-paste ready prompts** for staged execution using:
- Claude Code (structure, files, edits)
- Gemini CLI (analysis, critique, alternatives)

---

# OVERALL MODEL (KEEP IN MIND)

Goal:
Build a **concept-driven documentation system** for a concurrency toolkit.

Structure:
- Concepts → thinking
- Idioms → applied patterns
- Components → primitives
- Guides → system building
- API → generated reference (read-only)

Rules:
- Early stages = **NO real content**
- Only structure + intent
- Each stage must be **validated before continuing**

---

# STAGE 1 — SKELETON CREATION (Claude Code)

## Prompt (copy-paste)

You are working on a documentation system for a concurrency toolkit called "matryoshka".

Your task is to CREATE a mkdocs project skeleton (no real content yet).

Requirements:

1. Create this folder structure inside `docs_site/docs/`:

- index.md

- concepts/
  - mental_model.md
  - ownership.md
  - message_passing.md

- idioms/
  - pipelines.md
  - event_loop.md
  - worker_pool.md

- components/
  - mailbox.md
  - mpsc.md
  - pool.md
  - loop.md
  - wakeuper.md

- guides/
  - getting_started.md
  - building_pipeline.md
  - event_loop.md

- api/
  - index.md

2. Create `mkdocs.yml` with navigation reflecting:
Concepts → Idioms → Components → Guides → API

3. IMPORTANT:
- Each .md file must contain ONLY:
  - title
  - short "Purpose" section
  - bullet list of what should be written later
- DO NOT write real documentation content

4. Keep everything minimal and clean.

5. Use mkdocs-material theme.

Output:
- All files
- mkdocs.yml

Do not explain. Just generate files.

---

## CHECKPOINT 1

Run locally:

mkdocs serve

Verify:
- navigation works
- all pages visible
- no errors

---

# STAGE 2 — STRUCTURE REVIEW (Gemini CLI)

## Prompt (copy-paste)

You are reviewing a documentation structure for a concurrency toolkit called "matryoshka".

Here is the navigation structure and page grouping:

[PASTE mkdocs.yml HERE]

Task:

1. Analyze whether this structure reflects:
   - message-driven concurrency toolkit (not just a library)
   - clear separation of concepts vs components

2. Identify:
   - missing conceptual layers
   - overlaps between sections
   - naming problems

3. Suggest:
   - improvements to hierarchy
   - additions/removals of sections

Constraints:
- DO NOT write documentation content
- Focus only on structure and architecture

Output:
- concise critique
- list of actionable changes

---

## CHECKPOINT 2

Apply ONLY:
- renames
- file moves
- section adjustments

Do NOT add content.

---

# STAGE 3 — BUILD PIPELINE (Claude Code)

## Prompt (copy-paste)

Extend the mkdocs documentation project by adding a local build pipeline.

Requirements:

1. Create a file `docs_site/build.sh`

2. Script must:
   - delete docs/api
   - recreate docs/api
   - run odin doc generation into docs/api
   - run mkdocs build

3. Assume source code is in `../src` (adjust if needed)

4. Script must be simple, readable, and safe

5. Do not overengineer

Output:
- build.sh only

Do not explain.

---

## CHECKPOINT 3

Run:

./build.sh
mkdocs serve

Verify:
- API folder appears
- site builds successfully

---

# STAGE 4 — PAGE INTENT DEFINITION (Claude Code)

## Prompt (copy-paste)

You are defining documentation structure for a concurrency toolkit.

For EACH markdown file in this project, expand it into a structured template.

Rules:

1. DO NOT write real content

2. Each file must include:

- Title
- Purpose
- Sections like:
  - When to use
  - Guarantees
  - Relationships (to other components)
  - Examples (placeholder description only)

3. Tailor sections based on file type:

- Concepts → thinking, principles
- Idioms → patterns, composition
- Components → behavior, guarantees
- Guides → step-by-step structure

4. Keep everything concise and structured

5. No long explanations — only what should be written

Output:
- updated markdown files

---

## CHECKPOINT 4

Manual review:

Check:
- clarity of purpose
- no duplication between pages
- correct abstraction levels

---

# STAGE 5 — CROSS REVIEW (Gemini CLI)

## Prompt (copy-paste)

You are reviewing documentation templates for a concurrency toolkit.

Here are multiple markdown files defining documentation structure:

[PASTE SEVERAL FILES HERE]

Task:

1. Identify:
   - overlapping responsibilities between pages
   - unclear boundaries
   - missing topics

2. Evaluate:
   - are Concepts, Idioms, Components clearly separated?

3. Suggest:
   - merges
   - splits
   - renaming

Constraints:
- DO NOT write actual documentation
- Focus only on structure and clarity

Output:
- list of problems
- recommended fixes

---

## CHECKPOINT 5

Apply:
- structural refinements only

---

# STAGE 6 — OPTIONAL: LANDING PAGE POSITIONING (Claude Code)

## Prompt (copy-paste)

Rewrite index.md for a concurrency toolkit called "matryoshka".

Constraints:

- Keep it short (no more than ~30 lines)
- Must include:
  - what it is (toolkit, not library)
  - what user gets (components)
  - how docs are structured
- No deep explanations
- No marketing fluff

Output:
- index.md only

---

# WORKFLOW RULES

1. Always:
   - run one stage at a time
   - validate locally
   - commit after each stage

2. AI usage pattern:
   - Claude → build / modify
   - Gemini → critique / validate

3. Never:
   - mix structure and content early
   - skip checkpoints

---

# RESUME TEMPLATE

If you stop, resume with:

"Continue matryoshka docs from STAGE X.
Here is current mkdocs.yml and structure:
[PASTE]"

---

# END
```
