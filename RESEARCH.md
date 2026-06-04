# Research Notes

Checked on 2026-06-02.

## Existing apps

- Brim tracks Claude Code and Codex CLI usage from the macOS menu bar. Its site
  says it reads Claude logs at `~/.claude/projects`, Codex sessions at
  `~/.codex/sessions`, and refreshes Anthropic's usage endpoint only on demand.
- CodexBar is a macOS 15+ menu bar app for OpenAI Codex and Claude Code. It
  describes using local Codex app-server RPC, `codex /status` fallback, and
  Claude CLI `/usage`/`/status`.
- MeterBar is a free/open-source macOS quota monitor for Claude, OpenAI, and
  Cursor that says it reads credentials from CLI tools.
- Code Meter is an App Store / StreetCoding app for Claude, Codex, MiniMax,
  Z.ai, and OpenCode Go; it claims burn-rate tracking, widgets, alerts, and
  Keychain credential reading.
- CUStats, ClaudeUsageBar, ClaudeBar, AgentBar, and so-agentbar are additional
  small or single-developer tools covering various combinations of Claude,
  Codex, Gemini, Copilot, Cursor, and other coding agents.

## Claude implementation details from GitHub

- ClaudeBar has `ClaudeAPIUsageProbe`, `ClaudeCredentialLoader`, and
  `ClaudeUsageProbe`. The API probe calls
  `https://api.anthropic.com/api/oauth/usage` with bearer OAuth credentials and
  the `anthropic-beta: oauth-2025-04-20` header. Credentials come from
  `~/.claude/.credentials.json`, Keychain service `Claude Code-credentials`, or
  environment fallback. It also has a CLI `/usage` parser.
- AgentBar's `ClaudeUsageProvider` uses the same Anthropic OAuth usage endpoint
  and the same Keychain service. It merges model-specific seven-day windows such
  as `seven_day_sonnet` and `seven_day_opus`.
- Claude Analyst focuses on local Claude Code usage analytics from project
  JSONL data. That is useful for estimates and history, but it is not the exact
  quota source.

## Codex implementation details from GitHub

- AgentBar reads Codex rate-limit snapshots from `~/.codex/sessions`, like this
  app. Its important freshness behavior is that stale `resets_at` values are
  advanced by `window_minutes`; once a window has rolled over, the old usage
  percentage is treated as `0`.
- ClaudeBar includes a live Codex API probe for
  `https://chatgpt.com/backend-api/wham/usage` using `~/.codex/auth.json` OAuth
  credentials. It prefers HTTP headers such as
  `x-codex-primary-used-percent`/`x-codex-secondary-used-percent`, with response
  body fallback. This is a possible future improvement over local session logs.

## Official quota surfaces

- OpenAI's Codex pricing docs say Codex local messages and cloud tasks share a
  five-hour window, weekly limits may apply, and current limits are visible in
  the Codex usage dashboard or during CLI sessions with `/status`.
- Anthropic's Claude help says Claude, Claude Code, and Claude Desktop usage
  share the same usage limit. Claude Code users can monitor remaining allocation
  with `/status`.

## Practical conclusion

The app is possible, but exact quota monitoring is not a simple public API
integration. User-reported failures in Brim, MeterBar, and CodexBar make a
small local app tailored to our specific requirements reasonable. The defensible
architecture is local-first:

1. Use local logs for trend/activity estimates.
2. Use Codex `rate_limits` snapshots from local session logs when available,
   while rolling over expired windows to `0` current usage.
3. Use Anthropic's OAuth usage endpoint for exact Claude values when Claude Code
   credentials are available; refresh expired OAuth tokens when possible.
4. Cache exact Claude usage responses, but label them as cached when live API
   calls are unavailable or rate-limited.
5. Use each CLI's authenticated status/usage command or local RPC as a fallback
   exact-value path where available.
6. Avoid browser cookie scraping unless the user explicitly wants that tradeoff.
