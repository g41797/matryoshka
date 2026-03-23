# matryoshka Ring Logo Prompt

## Concept

A **ring of pixel-art gold mailboxes** (4–6, matching the "Endless Game" example of 4 threads),
each identical to the existing logo style, arranged in a circle facing inward or slightly angled.
Between each mailbox, a **playing card or envelope/letter** is mid-flight, glowing slightly,
as if just tossed from one mailbox to the next. The motion is clockwise (or implied circular).
The overall impression: an endless relay, a round-table game, messages never stopping.

> "The endless inter-threaded game..."

---

## Art Style

- **Pixel art**, 80s computer game aesthetic — same style as the existing `gold_mbox.png`
- Gold mailboxes with red flags (raised = has mail, some raised some lowered to show action)
- Cards/letters rendered as pixel-art playing cards or envelopes, possibly with a faint glow or motion trail
- Dark background (deep green like a poker table felt, or dark navy) to make the gold pop
- Optional: subtle pixel-sparkle or motion lines between mailboxes

## Palette

- Gold / amber (`#C9A84C` range) — mailboxes
- **Background**: transparent — works on both GitHub light and dark themes
- Red — mailbox flags
- White / cream — playing cards or envelopes
- Optional gold glow on the cards in flight

## Text

- None (icon only — works as GitHub avatar and README banner)

## Composition

- Square or circular crop (works as avatar)
- Ring centered in frame, slight perspective tilt optional (like looking at a round table from above-angle)
- 4–6 mailboxes in the ring

---

## Suggested Prompt (for AI image generator)

```
Pixel art logo, 80s retro video game style. A ring of 4 gold vintage American mailboxes
with red flags, arranged in a circle. Transparent background (no fill, no dark backdrop).
Between each mailbox, a pixel-art playing card or envelope is flying through the air,
mid-pass, as if being dealt clockwise around the table.
Some mailbox flags are raised (mail inside), some lowered.
Gold and amber color palette, red flags, white playing cards with faint golden glow.
Clean pixel art, no anti-aliasing, retro 8-bit aesthetic.
Square composition. No text.
```

---

## v2 Additions (gen_ring_logo.py)

The generated image was enriched with three extra elements that add emotional depth
matching the slogan *"The endless inter-threaded game..."*:

- **Varied card suits** — each of the 4 flying cards shows a different suit
  (♠ ♥ ♦ ♣), drawn as pixel-art glyphs. Red suits (♥ ♦) in crimson; black suits
  (♠ ♣) in dark grey so they read on the cream card body.
- **Slight asymmetry** — each card position is jittered by ±8 px and its flight
  angle varied by ±15°, so no two gaps look identical (seeded with `random.seed(42)`
  for reproducibility).
- **Broken / fallen mailbox** outside the ring — placed in the bottom-right corner
  beyond the ring radius. Its flag is painted down (a dark-grey overlay covers the
  raised-flag area). Beside it sits a neat pile of 4 fanned cards (♠ ♣ ♥ ♦),
  slightly rotated — melancholy but not dramatic.

---

## Verification Checklist

- [ ] Ring shape with 4 mailboxes
- [ ] Pixel art style consistent with `gold_mbox.png`
- [ ] Gold mailboxes with red flags (raised)
- [ ] 4 flying cards showing different suits (mix of red and black)
- [ ] No two card positions/angles look identical
- [ ] Broken mailbox visible outside ring, flag down, card pile at its side
- [ ] Transparent background
- [ ] Works as small avatar (64×64) — ring and motion still readable
