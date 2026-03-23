You are an expert Odin architect and senior technical writer, but not professor, you are also field developer

I need to merge 4 overlapping design documents for matryoshka into exactly 3 clean, final files under design/compose folder:

1. overview.md          → high-level mental model and motivation (1–2 pages max)
2. design.md            → THE NORMATIVE SPECIFICATION (single source of truth for APIs, contracts, invariants)
3. idioms.md            → practical patterns, golden rules, examples, anti-patterns

"Golden contract" - design/sync/golden-contract.md



=== INPUT DOCUMENTS ===
- design/sync/new-pool-design-ga-v2.md

- design/sync/poly_mailbox_proposal.md

- design/sync/new-idioms.md

- design/sync/new-itc.md

=== ADDITIONAL INPUT: EXISTING AUDIT REPORT ===
Here is a professional audit report that already lists all known contradictions and wrong claims in these exact 4 files:
- design/sync/contradictions.md

=== itc ===

It's library for inter-thread communications based on Odin programming language.
Main purpose - allow devs think in terms of flows and helper "objects"
instead of low-level os primitives.
For now there are 2 main "objects" presented:
- pool
- mailbox (in code may be mbox)

User data traveled within itc process:
- send/recv via mailboxes
- get/put using pool

There is one user provided "object" PolyNode and it's container Maybe(^PolyNode).
This approach allows itc provide functionality without knowledge regarding user data types.
Type erased intrusive inter thread communication.

Mailbox/pool definitions/examples/etc are placed in different documents with overlapping and contradictions.
You task as architect - create clear set of documentation.

Target audence - field programmers, non-English developers.
They don't like smart words, long sentences, inveriants, math approve of the concepts.
Don't be smart, be human, you are architect but also from the fields

Devs don't should to use itc, you only show one from lot of ways, you also have failures

You are speaking , there is not lecture in university


=== YOUR TASK ===
1. First, read all 4 documents + the audit report.
2. Explicitly list every contradiction you find (quote the conflicting parts).
3. Resolve ALL contradictions using these strict priorities:
   - Priority 1: new-itc.md for API signatures and return types
   - Priority 2: new-pool-design-ga-v2.md for FlowPolicy, pool_get modes, on_put
   - Priority 3: Strict ID panic model (unknown id = panic)
   - Priority 4: Unified ^Maybe(^PolyNode) ownership contract everywhere
   - Priority 5: Examples must be correct — add proper return-value checking for mbox_send / mbox_wait_receive; remove redundant pool_put calls
   - Priority 6: Choose ONE name for the dispose hook (flow_dispose or policy.dispose) and use it consistently everywhere

   You can ask questions or prepare separated file with questions - I'll fill it "online".
   Some decisions may be postponed - save former text with notes for recognition later + what should be provided instead.

4. Produce the three final files with:
   - Clean structure, tables, correct Odin code blocks
   - A short "Decision Log" section at the top of each file (what contradictions were resolved and how)
   - Cross-references to the Golden Contract where relevant

Start by outputting only **design.md** (the most important file). After I approve it, I will ask for overview.md and idioms.md.

Rules:
- Eliminate all duplication
- Make every example follow the Golden Contract
- Language: precise, technical, developer-focused, for non-english developers, humans, not math professors, field specialists
- No fluff, no ads. without pathetic
- Staff should be solved later - mark it for recognition with add. information what lacked

Begin.
