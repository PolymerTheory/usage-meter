# Usage Meter

Native macOS menu bar prototype for tracking Codex and Claude Code activity.

## What it does

- Adds a visible macOS status-bar item with four vertical bars:
  - Codex 5-hour activity
  - Codex 7-day activity
  - Claude 5-hour activity
  - Claude 7-day activity
- Colors bars green, yellow, or red as estimated usage increases.
- Opens a SwiftUI popover with provider details when clicked.
- Reads local Codex logs from `~/.codex/sessions`.
- Uses Codex `rate_limits` snapshots when present, including provider reset
  times.
- Uses the Anthropic OAuth usage endpoint for exact Claude quotas when Claude
  Code credentials are available from `~/.claude/.credentials.json` or the
  `Claude Code-credentials` Keychain item.
- Refreshes expired Claude OAuth access tokens when a refresh token is present,
  and stores the refreshed credentials back to the original credential source.
- Caches the most recent successful Claude usage response. If Anthropic returns
  `429`, Usage Meter backs off for one hour and labels cached Claude data as a
  cached fallback rather than a live reading.
- Lets you override estimated Codex token limits with `~/.usage-meter.json` if
  Codex rate-limit snapshots are unavailable.

## Current limitation

Codex can be exact when its local logs contain `rate_limits` snapshots. Claude
can be exact when the Anthropic OAuth usage endpoint is available. If Claude
credentials expire and a refresh token exists, Usage Meter attempts to refresh
them automatically. If Anthropic rate-limits usage or token refresh requests,
the app shows the most recent cached exact response when available and marks it
as cached. Local Claude JSONL logs are useful for activity history, but they are
not a reliable quota source and are not used for Claude quota percentages.

## Configuration

Optional config path:

```text
~/.usage-meter.json
```

Example:

```json
{
  "codex": {
    "shortWindowHours": 5,
    "longWindowDays": 7,
    "shortLimitTokens": 100000,
    "longLimitTokens": 500000
  },
  "claude": {
    "shortWindowHours": 5,
    "longWindowDays": 7,
    "shortLimitTokens": 300000,
    "longLimitTokens": 1500000
  }
}
```

These limits only affect estimated Codex token-log mode. Exact Codex
`rate_limits` and Anthropic OAuth usage snapshots override token-limit
estimates.

## Build and run

Development build, package, launch, and verify the menu bar item:

```sh
swift test
./script/build_and_run.sh --verify
```

After it has been built once, restart the existing app bundle without rebuilding:

```sh
./script/run.sh
```

Install the app into `~/Applications` so it can be launched from Finder,
Spotlight, Raycast, Alfred, etc.:

```sh
./script/install_app.sh
```

The app runs as a menu bar accessory and does not show a Dock icon.

## Suggested GitHub Repository

- Name: `usage-meter`
- Description: `macOS menu bar quota monitor for Codex and Claude usage`
