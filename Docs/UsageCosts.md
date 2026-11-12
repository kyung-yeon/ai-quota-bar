# Local API-equivalent cost estimates

The usage popup includes **Local API-equivalent estimate** and a client/provider/model breakdown. The amount covers all retained records found on this Mac, not a calendar month or the subscription quota window. It is a token-price estimate, **not a bill, subscription charge, or conversion of the quota percentage into money**. `+ ?` means the displayed amount is only the known subtotal. Missing prices, models, or request boundaries remain **unestimated**, never zero dollars.

The app scans in the background at launch, on wake, every five minutes, and on manual refresh. It does not need the corresponding CLI to be installed or signed in to read an existing history.

## Sources and coverage

| Client | Local source | Accounting |
| --- | --- | --- |
| Codex | `$CODEX_HOME/{sessions,archived_sessions}/**/*.jsonl`, default `~/.codex` | `turn_context` model and `event_msg/token_count` usage. Cached input is part of input; reasoning is already part of output. Repeated cumulative totals and copied event identities are deduplicated. The first total-only counter establishes a baseline; subsequent increments without request boundaries remain unestimated. |
| Claude Code | `$CLAUDE_CONFIG_DIR/{projects,transcripts}/**/*.jsonl`, default `~/.claude` | Assistant message usage: input/output, cache read, cache creation, and one-hour cache creation. Streaming updates merge by message/request identity using counter maxima. |
| OpenCode | `$XDG_DATA_HOME/opencode/opencode*.db`, default `~/.local/share/opencode`; `OPENCODE_DB` overrides the file | Read-only SQL projections of usage counters, model/provider IDs, and recorded cost. Supports `message`, `session_message`, and cumulative `session`/`session_v2` schemas. Positive recorded USD estimates take precedence. Otherwise supported exact OpenAI/Anthropic model IDs use the catalog. |

DeepSeek and other providers appear when recorded by OpenCode with provider/model identifiers. Their positive recorded cost can be displayed without guessing a price from an unrelated model. DeepSeek records without a positive recorded cost currently remain unestimated: its [official pricing](https://api-docs.deepseek.com/quick_start/pricing) has model-version and peak/off-peak rules, including holidays. A zero stored cost alone does not establish that usage was free.

OpenCode session totals can span multiple providers/models. They are shown as **mixed/unspecified · session totals** unless individual recorded message costs reconcile to the cumulative total. Frozen/migrated session counters merge with maxima, not sums. The canonical `opencode.db` wins for duplicate session IDs across databases. Legacy OpenCode JSON storage, remote machines, browser chats, custom roots not supplied in the app's environment, and other clients are not scanned. Environment variables set only in an interactive shell are not automatically available to a login-launched app.

## Pricing and accuracy

The bundled catalog was checked on **2026-11-12** against [OpenAI pricing](https://developers.openai.com/api/docs/pricing), the [GPT-5.4 model page](https://developers.openai.com/api/docs/models/gpt-5.4), the [GPT-5.1-Codex model page](https://developers.openai.com/api/docs/models/gpt-5.1-codex), and [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing). It uses standard text API rates per million tokens for exact supported model IDs; dated Claude snapshots use their base model's rate. The catalog is deliberately incomplete and is updated with app releases, not fetched remotely.

Input, output, cache reads, and Claude's five-minute/one-hour cache writes are priced separately. Claude Haiku 5.5's prompt-length tier is applied per request. Ambiguous older long-context requests and Codex total-only deltas are not priced. This is a **current standard-list-price comparison**, not historical invoice reconstruction. Service tiers, regional pricing, subscriptions, discounts, credits, taxes, tool charges, multimodal differences, and unrecorded cache-write premiums can change actual costs. OpenCode's stored estimates may reflect a different price snapshot. Deleted or unsupported records cannot be recovered. Copied records are deduplicated within each client; the app cannot reconcile the same request imported into different clients without a shared identity.

## Privacy and bounds

Only numeric usage, bounded model/provider IDs, and temporary deduplication identities are retained in memory. JSONL lines are decoded transiently to reach usage fields; conversation bodies are discarded immediately and never copied to another file or sent anywhere. SQLite queries return usage scalars only. No credentials, Keychain access, API calls, or log uploads are used by the cost scanner.

Each JSONL client scan is capped at 256 MiB, 10,000 files, 15 seconds, and 100,000 retained usage identities in total; lines over 2 MiB are skipped. OpenCode limits each query to 50,000 rows and 16 MiB of output, and each process to three seconds; at most 16 database files are considered, with a 20-second between-database deadline. Unreadable, oversized, truncated, unsupported, or capped sources are labeled **Partial scan**. Missing standard directories mean no local records, not a zero-dollar account balance. These bounds keep menu interaction responsive but mean very large histories show only a subtotal.
