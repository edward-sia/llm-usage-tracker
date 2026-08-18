# Claude Usage Bar

A tiny macOS menu bar app that always shows your Claude subscription usage:

```
5h 25% · W 26% · F 17%
```

- **5h** — the rolling 5-hour session limit
- **W** — the weekly limit across all models
- **F** (or another letter) — a weekly limit scoped to one model, e.g. Fable

Numbers turn amber at 50 % and red at 80 %. Hover for reset countdowns. Click for
bars, exact reset times, a refresh button, a link to the usage page, and settings.

It shows the same numbers as the claude.ai usage page and the Claude Code status
line, without keeping a browser tab open or clicking anything.

## Requirements

- macOS 14 or newer
- [Claude Code](https://claude.com/claude-code) installed and signed in (`claude` → log in). The app reuses that login.
- To build from source: Xcode Command Line Tools (`xcode-select --install`)

## Install from source

```bash
git clone <this repo>
cd llm-usage-tracker
make install
```

`make install` builds a release binary, wraps it in `ClaudeUsageBar.app`, ad-hoc
signs it, copies it to `/Applications`, and launches it. Turn on **Launch at
login** from the click menu if you want it always there.

Other targets: `make test` (unit tests), `make run` (build and launch from
`build/`), `make clean`.

If you download a pre-built zip instead of building, macOS will quarantine it.
This build is ad-hoc signed, not notarized, so Gatekeeper flags any copy that
arrived via a browser or other quarantine-aware app; a copy you build yourself
with `make install` is never quarantined in the first place. Remove the flag
before launching a downloaded copy:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

## How it works

1. Reads the OAuth access token that Claude Code stores in the macOS Keychain
   (item `Claude Code-credentials`), the same way Claude Code's own status line
   integrations do. Falls back to `~/.claude/.credentials.json`.
2. Calls `GET https://api.anthropic.com/api/oauth/usage` every 60 seconds (or
   30 s / 3 min / 5 min from the menu), on wake from sleep, and when you click
   Refresh.
3. Renders the `limits` from the response in the menu bar.

The app is read-only: it never writes to the Keychain and never refreshes the
token itself (Claude Code does that). If the token expires, the app shows a
warning and picks up the new token on the next refresh after you use Claude
Code again.

## Privacy

Nothing leaves your Mac except the request to Anthropic's usage endpoint,
authenticated with your existing Claude Code token. There is no telemetry, no
third-party server, and no storage beyond the refresh-interval preference.

## Troubleshooting

| Menu bar shows | Meaning | Fix |
|---|---|---|
| `⚠︎ not signed in` | No Claude Code credentials found | Run `claude` in a terminal and log in |
| numbers followed by `⚠︎` | Last refresh failed; numbers are stale | Hover or click for the reason (offline, token expired, rate limited, API error) |
| `…` | First fetch has not finished | Wait a second; hover shows "Loading Claude usage…" |

"Launch at login" only works when the app runs from `/Applications` (i.e. after
`make install`), because macOS registers login items by bundle.

## Development

```bash
swift test          # unit tests for everything except the AppKit glue
swift build         # debug build
make run            # build the .app and launch it
```

Structure: `Sources/ClaudeUsageBarCore` (models, credential reading, API client,
formatting, poller — all unit-tested, no AppKit) and `Sources/ClaudeUsageBar`
(the menu bar UI). Design notes live in `docs/superpowers/specs/`.

## Roadmap

- Floating always-on-top overlay as an alternative to the menu bar
- Notifications when a limit crosses a threshold
- Signed/notarized releases and a Homebrew cask

## License

MIT — see `LICENSE`.
