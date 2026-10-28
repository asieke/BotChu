# BotChu Analytics v2 — visual spec

File: `dashboard-v2.html` (one static page, CSP `default-src 'none'`, all inline, system font).
States: `?theme=light|dark` (default follows the OS), `?state=filtered` (two chips set).

## Tokens
- One `:root` block with `color-scheme: light dark` and `light-dark(light, dark)` per token; `[data-theme]` only sets `color-scheme`.
- Categorical `--s1…--s7` = dataviz reference palette, validated (adjacent CVD ΔE ≥ 8.4, normal ≥ 19.3, both modes). `--other` gray for slot 8+ and unpriced models.
- Entity → slot is **fixed by its index in the dimension's list** (`D.<dim>.v`), never by rank, so a filter never repaints survivors. Bots: Fox blue, 10x orange, QA aqua, Pixel yellow, Research pink.
- Outcome uses the existing status colors (finished blue, failed red, stopped orange, in progress gray).
- Token mix uses a neutral ink ramp (`--t-in/-cr/-cw/-out`) so it never collides with an entity hue.

## Labels
Models show human names everywhere (Opus 5.5, GPT-6 Astra, DeepSeek V4.1 Flash…); the raw ID is only the table row's `title`.

## Provenance encoding (the core idea)
| Provenance | Number | Mark |
|---|---|---|
| Actual (OpenRouter billed) | `$40.12` | solid fill |
| Estimated (list price, dated) | `≈$1,214` | quiet hatch: full hue + 1.5 px stripes every 5 px at 66% (SVG `mask="url(#est)"`, CSS `.est`) |
| Unpriced | `—` | dashed swatch; counted in the toolbar chip, which filters to them |
A total that contains any estimate is `≈$`. Legend chips sit once, top-right of the toolbar.

## Layout (max-width 1180, 16 px gutters, cards r10, 1 px `--border`)
1. Sticky toolbar: range segmented (7/30/90) · date span · provenance legend. Row 2: filter chips (`Dim value ✕`, OR within a dimension, AND across) + `+ Filter` select (optgroups per dimension) + `Clear all` at ≥ 2 chips.
2. KPI row: grid `1.35fr repeat(5,1fr)`; value 24/600; detail 12 px. Spend tile carries an actual|est split bar (flex by $). Wasted tile toggles the Failed + Stopped chips (`aria-pressed`, accent ring). Deltas: ▲/▼ + color by whether up is good.
3. `Spend a day by [dimension]` (2fr): stacked columns ≤ 24 px, 2 px gap between entities, 3 px rounded top, actual below estimate within an entity; legend with per-entity totals; per-column tooltip. Tokens card (1fr): 100% mix bar + rows, then cache hit by bot.
4. Efficiency: 3×2 cards ranked by $ impact. Card = rank + title, `≈$N` + unit (`redone`, `spent`, …), one single-line fact, `Filter to these` (toggles to `Filtered ✓`). Computed from the range only, so cards stay put while filtering.
5. Breakdown: `Group by [dim] then [dim|—]`; sortable headers (`aria-sort`, ↓/↑); row click adds that row's filter(s); chevron expands level 2; tfoot Total; share-of-spend bar uses the entity hue with the same solid/hatch split. Level 2: no dot, name at 54 px (under parent's name), `--muted` bar.
6. Provider allowance: one row per profile, 5-hour + weekly meters (≥ 80 % = warn fill + ⚠), Stale badge.
7. `About these numbers` closed `<details>`, six short definitions.

## Metric definitions
- Cache hit = cache read ÷ (input + cache read + cache write).
- Per finished task = spend of a finished task's turns + sub-agent runs ÷ finished tasks.
- Wasted = spend on failed + stopped. Retried = failed/stopped runs whose task ran again later. Failure rate = failed ÷ (finished + failed + stopped).
- Model-swap savings re-price the same tokens at the other model's list price.
- Cache-gap savings move the bot's uncached input to cache read at the other bots' rate (`others N%`).
- Fan-out = task whose sub-agent spend exceeds its own turns; impact = difference.

## Reuse for the rest
| Not mocked | Reuse |
|---|---|
| Custom date range | add `From/through` dates after the segmented control (today's inputs) |
| "Not everything could be read" callout | keep today's warn callout above the KPI row |
| Stack by outcome / account / kind | already wired in the `by` select |
| Table view of the chart | today's `Show as a table` details under the chart |
