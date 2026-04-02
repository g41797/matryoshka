# matryoshka — Contributor Rules

> Rules for writing and reviewing documents and code in this project.

> See [Design Hub](design_hub.md) for API contracts, layer structure, and rules.
> See [Advices](advices.md) for recommended patterns.

---

## Document Writing Rules

When editing documents, follow these rules:

**Sentences**

- One idea per line.
- Split compound sentences — do not chain clauses with commas.
- Do not pack a full explanation into one sentence.
- Use bullets or short sequential sentences instead.
- If you feel the urge to write "which", "that", or "because" mid-sentence — stop. Split.
- When writing multiple short sentences in sequence (not a bullet list), add two trailing spaces to every line except the last. Without them, Markdown joins them into one long line. Do not use blank lines between them as a workaround — use two trailing spaces instead.
- Exception: README.md is rendered by GitHub (CommonMark), which supports trailing `\`. Use `\` there only.

**Language**

- Write for non-English developers.
- Use clear, direct language, avoiding jargon where simpler terms suffice, to ensure accessibility for a global audience.
- If you would not say it to a colleague at a whiteboard — rewrite it.

**Lists**

- Use bullet lists for sets of items, attributes, or steps.
- Use numbered lists only when order matters for correctness.
- Always leave a blank line between a label or sentence and the first list item. Without it, Markdown renders the list as inline text.

**Sequential steps**

- Write as a bullet list, not as a run-on sentence.
- Label the context: `Send side:` / `Receive side:` / `Algorithm:` etc.
- Leave a blank line after the label, before the first bullet.

**Tables**

- Use for result codes, mode behavior, and rules.
- Keep column count minimal — two or three columns maximum.

**Prose paragraphs**

- Reserve for motivation and explanation, not for API contracts.
- API contracts go in tables or bullet lists.

**Source files**

- Source files know nothing about blocks — no layer references in comments or docs.
- No forward references to terms not yet defined in the document.
- Always use the two-value form to read the inner value of a `Maybe`: `ptr, ok := m.?`
- Never use the single-value form `ptr := m.?` — it panics if nil.
- Never cast or dereference around `.?`.

**Code snippets in documents**

- Every code snippet must come from an existing source file in this project.
- The source file must compile and pass tests.
- Files listed in `.gitignore` are not valid sources.
- Place a source tag immediately before each code fence:
  `<!-- snippet: <path>:<start_line>-<end_line> -->`
  Path is relative to `flat/`.
  Example: `<!-- snippet: examples/block1/builder.odin:7-14 -->`

- When the source code changes, find all snippets referencing that file and update them.
  Search: `grep -r "snippet:.*<filename>" docs/`

- A snippet may be shortened with `// ...` to skip irrelevant lines.
  The tag still points to the full range.

**Odin doc comments (doc.odin)**

- Use `[[Text;URL]]` for clickable hyperlinks in odin-doc output.
- Example: `[[Documentation;https://g41797.github.io/matryoshka/]]`
- Plain URLs are not guaranteed to render as links — always use `[[ ]]`.

**Cross-block references**

- A block may reference earlier blocks.
- A block must never reference later blocks.
- Within a block, do not mention concepts defined later in the same block.

---

## Code Generation Rules

When generating or reviewing Odin code for this project, follow these rules:

**Status checks**

- Check the return value of every matryoshka API call (`mbox_send`, `mbox_wait_receive`, `pool_get`, `pool_get_wait`, and so on...).
- Check the return value of every memory allocation (`new`, `make`, ...).
- If the correct handling of a status is not obvious, add a comment: `// TODO(developer): handle <status> — <what could go wrong>`.
- Do not silently ignore a non-Ok status.

**Resource cleanup**

- Every allocated resource must be released — on success and on error.
- Use `defer` for cleanup that must happen on all exit paths.
- After `pool_get` succeeds, ensure `pool_put` is reachable on every path (including error paths).
- After `mbox_close`, the returned list is yours — walk it and handle each item. Do not discard it.
- After `pool_close`, the returned list is yours — walk it and handle each item as your shutdown strategy requires.

**Node ownership**

- Never send or put back a node that is still linked.
- `mbox_send` and `pool_put` always panic if the node is linked — in debug and release.
- This is intentional: silent list corruption is worse than a loud crash.
- A node becomes unlinked when received (`mbox_wait_receive`) or retrieved from the pool (`pool_get`).

**MayItem**

- Always use `ptr, ok := m^.?` — never the single-value form.
- After a transfer (`mbox_send`, `pool_put`), do not use `m^` — it is nil.
- If `m^` is still non-nil after `pool_put`, the pool is closed. Dispose manually.

**Type aliases**

- When example or user code imports matryoshka, declare aliases for types used more than once and use them in code
- Each package declares aliases once in a shared file (e.g., `types.odin`).
- Example: `PolyNode :: matryoshka.PolyNode`
- Use the alias in all proc bodies. Keep `matryoshka.PolyNode` only in struct field definitions and imports.

---

## Work Tracking

For any iterative or long-running task, maintain a tracking entry below.
Each entry: task name, link to tracking file, current status, what's next.
When a task is complete, remove its entry.

This section is the resume point after `/clear` or a new session.

### Active tasks

NOP

---
