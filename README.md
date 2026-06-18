# Usage Meter

A lightweight macOS menu bar app that shows your [Claude](https://claude.ai) and [Codex](https://openai.com/codex) quota at a glance.

![Popover showing Codex and Claude usage detail](docs/popover.png)

![Menu bar icon showing four coloured quota bars](docs/menubar.png)

## What it does

Four vertical bars live in your menu bar — green, yellow, or red as usage rises:

| Bar | What it shows |
|-----|---------------|
| 1 | Codex 5-hour window |
| 2 | Codex 7-day window |
| 3 | Claude 5-hour window |
| 4 | Claude 7-day window |

Small dots under the bars show whether the corresponding agent appears to be
actively processing a turn. The Codex dot is driven by live Codex desktop
app-server events. The Claude dot uses Claude Code lifecycle hooks when enabled,
with local project activity as a fallback.

Click the icon to open a detail popover with exact percentages, reset times, and a timestamp showing how fresh the data is. Click anywhere outside to dismiss it.

**Data sources:**

- **Claude** — reads the [Anthropic OAuth usage endpoint](https://api.anthropic.com/api/oauth/usage) using the credentials that Claude Code stores locally. Refreshes expired OAuth tokens automatically. Falls back to the most recent cached response if the API is unavailable. Its activity dot uses [Claude Code hooks](https://code.claude.com/docs/en/hooks) for prompt, tool, stop, failure, permission, and idle events.
- **Codex** — reads exact `codex.rate_limits` messages from the current `~/.codex/logs_2.sqlite` database. It also supports legacy `~/.codex/sqlite/logs_2.sqlite` and `~/.codex/sessions` snapshots, with token-counting estimates as the final fallback. The activity dot selects the freshest database and supports both modern response-stream pulses and legacy app-server events.

Quota data refreshes every 5 minutes and also on every popover open. Activity
dots refresh about once per second.

## Requirements

- macOS 14 (Sonoma) or later
- **Claude**: Claude Code in the [Claude desktop app](https://claude.ai/download) or CLI, signed in locally.
- **Codex**: The [Codex desktop app](https://openai.com/codex) or CLI, signed in and used at least once.

## Install

### Option A — Download pre-built app (easiest)

1. Go to the [Releases page](../../releases) and download `UsageMeter.zip`.
2. Unzip and move `UsageMeter.app` to `~/Applications` (or `/Applications`).
3. Open it: `open ~/Applications/UsageMeter.app`

For a private repository, authenticate GitHub CLI and download the release:

```sh
gh auth login
gh release download v0.1.0 \
  --repo PolymerTheory/usage-meter \
  --pattern UsageMeter.zip \
  --dir /tmp && \
  unzip -o /tmp/UsageMeter.zip -d ~/Applications && \
  open ~/Applications/UsageMeter.app
```

The shorter anonymous `curl` download works only if the repository is public.

> **First launch note:** macOS may show a security warning because the app
> isn't notarized. Right-click (or Control-click) `UsageMeter.app` and choose
> **Open**, then confirm in the dialog. You only need to do this once.

### Option B — Build from source

Requires Xcode command-line tools (`xcode-select --install`).

```sh
git clone https://github.com/PolymerTheory/usage-meter.git
cd usage-meter
./script/install_app.sh          # builds release binary, installs to ~/Applications
```

The script installs Claude activity hooks and launches UsageMeter when the
build finishes.

Pass `--debug` to build a debug binary instead:

```sh
./script/install_app.sh --debug
```

## Usage

UsageMeter runs as a menu bar accessory with no Dock icon. After opening it you should see four small bars appear in your menu bar. Click them to see the detail popover; click anywhere else to dismiss it.

On first launch, click **Enable Claude activity** in the popover. UsageMeter
merges its lifecycle hooks into `~/.claude/settings.json`; it does not replace
other Claude settings or hooks. Existing Claude Code sessions may need to be
restarted once after enabling the integration.

To have it launch at login, add it to **System Settings → General → Login Items**.

## Configuration (optional)

You can override the token limits used for Codex fallback estimates. Create `~/.usage-meter.json`:

```json
{
  "codex": {
    "shortWindowHours": 5,
    "longWindowDays": 7,
    "shortLimitTokens": 100000,
    "longLimitTokens": 500000
  }
}
```

These values only affect the estimated token-log mode. Exact Codex `rate_limits` snapshots and the Anthropic OAuth usage API always take priority.

## Uninstall

```sh
pkill -x UsageMeter          # quit the app
rm -rf ~/Applications/UsageMeter.app
rm -f ~/Library/Caches/UsageMeter/claude-usage.json    # cached Claude data
rm -f ~/Library/Caches/UsageMeter/claude-rate-limit.json
```

## Known limitations

- **Unofficial APIs.** Both the Anthropic OAuth usage endpoint and the Codex session log format are undocumented and may change without notice. If usage data stops appearing, check the [Issues](../../issues) page.
- **Claude usage API lag.** The Anthropic usage endpoint is not real-time — figures can lag actual usage by a few minutes. If you have just hit your limit you may briefly see e.g. 95% before the API catches up to 100%.
- **No separate Codex API call.** Codex quota is read from local database/session events, so the snapshot is only as fresh as the most recent Codex activity.
- **Activity dots are best-effort.** The Codex dot depends on Codex desktop's local sqlite telemetry format. The Claude dot is deterministic when Claude Code lifecycle hooks fire, with a less precise local-log fallback before hooks are enabled.
- **Not notarized.** The app is built locally and is not signed with an Apple Developer certificate, so macOS will prompt you to confirm the first launch (see install note above).
- **macOS 14+ only.** The app uses SwiftUI APIs introduced in Sonoma.

## Troubleshooting

If either provider shows unavailable data, run the privacy-safe diagnostics
command and include its output in a bug report:

```sh
~/Applications/UsageMeter.app/Contents/MacOS/UsageMeter --diagnose
```

The report lists detected data locations and provider errors, but does not
print credentials, prompts, or conversation content.

## Building for release / creating a GitHub release

```sh
./script/release.sh                   # build dist/UsageMeter.zip
./script/release.sh --publish v0.1.0  # push main and create a GitHub release
```

## Development

```sh
swift test                           # run unit tests
./script/build_and_run.sh --verify   # build, launch, and confirm menu bar item
./script/build_and_run.sh --debug --verify   # same with debug binary
```

## License

MIT — see [LICENSE](LICENSE).
