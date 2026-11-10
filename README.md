# usage-query

A macOS-first menu bar tool for checking local AI agent usage across Codex and Claude Code.

The app reads local usage data in a privacy-preserving way:

- Codex: scans `~/.codex/sessions/**/*.jsonl` and reads `token_count.last_token_usage`, matching the current cc-switch local session usage view.
- Codex rate limits: reads `token_count.rate_limits` from session JSONL, uses the fuzzy 5h / 7 days usage percentages, ignores expired snapshots, and infers approximate token limits from local metered token consumption.
- Claude Code: scans `~/.claude/projects/**/*.jsonl`, preferring `message.usage.*` fields and estimating tokens from conversation text only when usage fields are missing.
- Claude Code rate limits: Claude Code does not log its 5h / 7 days limits, it only passes them to a status line command. UsageQuery can be that command (see below) and then shows the same percentages and reset times as `/usage`, plus an inferred token limit. Without it, the Claude cards show local token usage for the rolling 5h / 7 days windows.
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

## Claude 5h / 7 days limits

Add UsageQuery as the status line command in `~/.claude/settings.json` (the Settings tab shows the snippet with the right path and a Copy button):

```json
"statusLine": {
  "type": "command",
  "command": "'/path/to/UsageQuery' --statusline-bridge"
}
```

Each time Claude Code updates its status line, the bridge stores the two percentages and reset times in `~/Library/Application Support/UsageQuery/claude-rate-limits.json` and prints `5h 42% · 7d 18%` as the status line. Nothing else from the status line payload is stored, and no credentials or network calls are involved.

To keep an existing status line, pass it after `--`; the bridge forwards stdin to it and prints its output instead:

```json
"command": "'/path/to/UsageQuery' --statusline-bridge -- ~/.claude/statusline.sh"
```

Limits appear only for Claude subscription logins, after the first response in a session.

## Floating window

The picture-in-picture button in the header (or Settings) opens a compact always-on-top window with the 5h / 7 days meters for both agents. It can be dragged anywhere, shows on every Space, and reopens at its last position on next launch. Usage refreshes every 60 seconds while it is open.

## Current Scope

- Local usage totals for today, 7 days, and 30 days.
- Inferred Codex and Claude Code 5h and 7 days limit hints.
- Codex and Claude Code provider breakdowns.
- Authoritative vs estimated event counts.
- Optional manual token budgets for estimated remaining usage.
- No webpage scraping of subscription quota bars.
