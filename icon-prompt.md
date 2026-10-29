# AiQuotaBar app icon

Redesigned with the built-in `image_gen` tool on 2026-10-29. The previous
graphite-and-mint app icon was supplied as the edit reference. The terminal
and renewal arrow were replaced with two quota bars to represent the app's
multi-provider usage display. Provider marks remain separate and unchanged.

## Final prompt

Use case: logo-brand / style-transfer. Redesign the supplied AiQuotaBar macOS app icon as a much cleaner final production icon. This utility monitors remaining usage quotas for two AI coding tools. Keep the dark graphite and mint identity, but replace the terminal prompt and circular renewal arrow entirely with just two bold horizontal quota meters, neatly stacked and centered: upper capsule is 80% mint filled with a subdued dark track for the remaining 20%, lower capsule is 55% soft ice-white filled with the same subdued track. Both meters have identical overall lengths, generous thickness and rounded ends. Flat, precise, minimal geometry with restrained native macOS polish, matte deep graphite rounded-square tile, only a very subtle edge highlight, no inflated 3D bevels or gloss. The two simple meters must be highly legible at 16–32 pixels. Output a single square 1024x1024 finished app icon, front-facing, with standard even macOS icon margins and actual alpha transparency outside the rounded-square tile. No words, letters, numbers, terminal chevron, arrows, circle, sparkles, provider logos, border frame, mockup, or extra objects. No cast shadow outside the tile. Two quota meters are the complete central symbol. This is the actual app icon asset, not a presentation sheet.

## Production assets

`AppIcon.png` is the selected image normalized to 1024×1024 with macOS `sips`,
preserving alpha transparency. `AppIcon.icns` contains all standard 16, 32,
128, 256, and 512 point sizes at 1x and 2x, packaged with `iconutil`.
