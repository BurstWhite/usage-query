# usage-query

A macOS-first menu bar tool for checking local AI agent usage across Codex and Claude Code.

The app reads local usage data in a privacy-preserving way:

- Codex: scans `~/.codex/sessions/**/*.jsonl` and reads `token_count.last_token_usage`, matching the current cc-switch local session usage view.
- Codex rate limits: reads `token_count.rate_limits` from session JSONL, uses the fuzzy 5h / 7 days usage percentages, ignores expired snapshots, and infers approximate token limits from local metered token consumption.
- Claude Code: scans `~/.claude/projects/**/*.jsonl`, preferring `message.usage.*` fields and estimating tokens from conversation text only when usage fields are missing.
- Conversation text is read only in memory for estimation. The app cache stores token counts and metadata, not prompt or response text.

## Run

```sh
swift run UsageQuery
```

## Test

```sh
swift run UsageQueryCoreTests
```

## Build

```sh
swift build --product UsageQuery
```

## Current Scope

- Local usage totals for today, 7 days, and 30 days.
- Inferred Codex 5h and 7 days limit hints.
- Codex and Claude Code provider breakdowns.
- Authoritative vs estimated event counts.
- Optional manual token budgets for estimated remaining usage.
- No webpage scraping of subscription quota bars.
