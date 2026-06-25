# AGENTS.md

Guidance for coding agents working in this repository.

## Project Shape

This is a Swift 6.0 package targeting macOS 14+.

- `UsageQueryCore`: UI-free library for scanning, parsing, aggregation, token estimation, caching, and models.
- `UsageQueryApp`: SwiftUI menu bar app using `MenuBarExtra`.
- `UsageQueryCoreTests`: standalone executable test runner. This repo does not use XCTest.

Keep provider parsing, token math, cache behavior, and privacy-sensitive logic in `UsageQueryCore`. Keep SwiftUI views and app state in `UsageQueryApp`.

## Build And Test

Use these commands in restricted environments:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/usage-query-clang-cache \
swift run --disable-sandbox --scratch-path .build --cache-path .swiftpm-cache UsageQuery
```

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/usage-query-clang-cache \
swift run --disable-sandbox --scratch-path .build --cache-path .swiftpm-cache UsageQueryCoreTests
```

Before finishing code changes, run the test runner and build the app:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/usage-query-clang-cache \
swift run --disable-sandbox --scratch-path .build --cache-path .swiftpm-cache UsageQueryCoreTests

CLANG_MODULE_CACHE_PATH=/private/tmp/usage-query-clang-cache \
swift build --disable-sandbox --scratch-path .build --cache-path .swiftpm-cache --product UsageQuery
```

`CLANG_MODULE_CACHE_PATH` gives Swift a writable module cache. `--disable-sandbox` is needed because the app reads local agent state under `~/.codex/` and `~/.claude/`.

## Data Flow

The intended flow is:

```text
UsageProvider implementations
  -> UsageScanner
  -> UsageAggregator
  -> UsageViewModel
  -> UsageDashboardView
```

`UsageProvider` in `Models.swift` is the central provider abstraction. Providers expose local usage events through `scanLocal(since:)`, health through `healthCheck()`, and optional Codex rate-limit metadata through `scanRateLimitSnapshots(since:)`.

## Provider Rules

Codex:

- Read `~/.codex/sessions/**/*.jsonl` read-only.
- Match cc-switch's local Codex session usage view: use `event_msg` records where `payload.type == "token_count"` and read `payload.info.last_token_usage`.
- Extract fuzzy rate-limit state from `payload.rate_limits` on those same `token_count` session events.
- Do not use `state_5.sqlite`, `logs_2.sqlite`, `response.completed`, or websocket `codex.rate_limits` compatibility paths for Codex usage or limit cards.
- Treat `primary.window_minutes = 300` as the 5h window and `secondary.window_minutes = 10080` as the 7 days window.
- Ignore expired rate-limit snapshots when inferring current limits.
- Infer approximate Codex token limits in `UsageAggregator`, not in the provider: `inferredLimitTokens = observedMeteredWindowTokens * 100 / usedPercent`.

Claude Code:

- Read `~/.claude/projects/**/*.jsonl` read-only.
- Prefer `message.usage.*` fields and mark those events `authoritative`.
- Only use `TokenEstimator` on `message.content` when usage fields are absent, and mark those events `estimated`.
- Stream JSONL line by line; do not load large conversation files into memory wholesale.

## Privacy Requirements

Conversation text is sensitive.

- Do not persist prompt text, response text, tool input, tool output, `instructions`, raw websocket bodies, or raw session JSONL lines.
- `ConversationRecord` is an in-memory-only temporary shape for fallback token estimation.
- `UsageCache` may store numeric token counts and metadata only: provider, source, timestamps, session/request IDs, model, token counts, cost estimate, and confidence.
- Tests should include privacy assertions when changing cache or parser behavior.

## Aggregation Rules

`UsageAggregator` should remain pure and stateless.

- Period summaries filter `UsageEvent` by the selected UI period.
- Provider summaries include total/input/output/cache tokens, model breakdown, and authoritative vs estimated counts.
- Codex 5h and 7 days limit cards are inferred from the latest non-expired `CodexRateLimitSnapshot` plus locally observed metered token usage in that same rolling window.
- Manual budgets are fallback UI hints for older daily/weekly estimated quota cards; do not use manual values for Codex 5h/7d when rate-limit snapshots exist.

## UI Rules

`UsageQueryApp` is a compact menu bar utility, not a landing page.

- Keep the window dense and scannable.
- Use tabs for Overview, Codex, Claude, and Settings.
- Show whether data is authoritative or estimated.
- Surface unavailable data clearly, for example `no rate snapshot` or `remaining unknown`.
- Keep expensive scanning off the main actor; use `Task.detached` as in `UsageViewModel`.

## Test Guidance

Tests live in `Tests/UsageQueryCoreTests/UsageQueryCoreTests.swift` and are called manually from `@main`.

When changing parsing or aggregation, add fixture-style tests using temporary homes and synthetic JSONL/cache records. Keep tests deterministic and avoid reading the developer's real `~/.codex` or `~/.claude` data.

Useful existing helpers:

- `temporaryHome()`
- `createCodexFixtureDatabase(at:)`
- `insertCodexLog(db:timestamp:body:)`
- `expect(_:_:)`
- `require(_:_:)`

## Editing Notes

- Prefer small, focused changes.
- Do not add dependencies unless the benefit is clear and the SwiftPM setup remains simple.
- Do not rewrite generated build artifacts or cache directories.
- Keep `.build/`, `.swiftpm-cache/`, `.swiftpm/`, and `.vscode/` out of commits.
