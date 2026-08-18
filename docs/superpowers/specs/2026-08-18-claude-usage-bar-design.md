# Claude Usage Bar — design (v1)

Date: 2026-08-18
Status: approved

## What it is

A native macOS menu bar app that shows your Claude subscription usage at all
times, without clicking anything:

```
5h 25% · W 26% · F 17%
```

It reads the OAuth token that Claude Code already stores in the macOS Keychain,
polls Anthropic's usage endpoint every 90 seconds, and renders the three limits
(5-hour session, weekly all-models, weekly per-model such as Fable) as colored
text in the menu bar. Clicking opens a menu with bars, reset times, and a few
controls. There is no Dock icon, no window, and no login flow of its own.

## Why

- The claude.ai usage page has to be kept open and refreshed by hand.
- The built-in Claude menu bar item needs a click to reveal the numbers.
- The Claude Code terminal status line only shows while a session is open.

## Constraints and decisions

| Decision | Choice | Why |
|---|---|---|
| Stack | Swift, AppKit `NSStatusItem`, Swift Package Manager, macOS 14+ | Tiny binary, no runtime, native look, easy to build from source and open source. No Xcode project needed. |
| Menu bar text | All three limits, compact, colored by threshold | Fits in the menu bar; the whole point is seeing all numbers at a glance. |
| Refresh interval | 90 s default; user-selectable 60 s / 90 s / 3 min / 5 min | Numbers move in whole percents; the endpoint is shared and rate-limited, so 60 s is the floor. Also refreshes on wake, on manual click, and on menu open (debounced). |
| Scope | Menu bar only | The floating overlay is a later, additive feature. |
| Credentials | Read-only. Never refresh, never write to the Keychain | Refreshing could rotate the refresh token out from under Claude Code and log the user out. Claude Code refreshes on its own; we re-read. |
| Keychain access | Shell out to `security find-generic-password` | Same path Claude Code and `ccstatusline` use; it did not trigger a permission prompt when tested. Using the Security framework directly from a new binary would prompt. |

## Data source

Verified 2026-08-18 against a live account.

**Token.** macOS Keychain generic password, service `Claude Code-credentials`.
The secret is a JSON blob:

```json
{ "claudeAiOauth": { "accessToken": "...", "refreshToken": "...", "expiresAt": 1755509769617,
                     "scopes": ["user:inference", "..."], "subscriptionType": "max",
                     "rateLimitTier": "default_claude_max_5x" } }
```

Only `claudeAiOauth.accessToken` is used. Read with:

```
security find-generic-password -s "Claude Code-credentials" -w
```

Fallback for people who use the file store: `~/.claude/.credentials.json`, same
JSON shape.

**Endpoint.**

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

**Response (fields we use).** The `limits` array is the primary source. The
top-level `five_hour` / `seven_day` objects are a fallback if `limits` is
missing, empty, or yields no usable entry (no `kind` + `percent`) — so a
shape change in `limits` degrades to the two basic numbers instead of an error.

```json
{
  "five_hour": { "utilization": 25, "resets_at": "2026-08-18T06:59:59.531450+00:00" },
  "seven_day": { "utilization": 26, "resets_at": "2026-08-23T13:59:59.531474+00:00" },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 25, "severity": "normal",
      "resets_at": "2026-08-18T06:59:59.531450+00:00", "scope": null, "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 26, "severity": "normal",
      "resets_at": "2026-08-23T13:59:59.531474+00:00", "scope": null, "is_active": true },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 17, "severity": "normal",
      "resets_at": "2026-08-23T13:59:59.531690+00:00",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
  ]
}
```

Other top-level fields (`extra_usage`, `spend`, `seven_day_opus`, etc.) are
ignored in v1. The decoder must tolerate unknown fields and nulls everywhere.

## Behavior

### Menu bar title

- One segment per limit, joined by ` · `.
- Label per `kind`:
  - `session` → `5h`
  - `weekly_all` → `W`
  - `weekly_scoped` → first letter of `scope.model.display_name`, uppercased
    (`Fable` → `F`). If two scoped limits share a first letter, use the first
    two letters. If `display_name` is missing, use `M`.
  - Any unknown `kind` → first letter of the kind, uppercased. Unknown kinds
    are still shown, so new limits from Anthropic appear without an update.
- Order: `session`, `weekly_all`, then scoped limits in API order, then unknown kinds.
- Percent is an integer with `%`.
- Color per segment by percent: under 50 → normal label color; 50–79 → amber
  (`systemOrange`); 80 and above → red (`systemRed`). Thresholds live in one
  place in `Formatting.swift`.
- Font: system menu bar font, monospaced digits so the width does not jitter.
- Tooltip (on hover): one line per limit, e.g.
  `Session (5h): 25% — resets in 4h 22m` and a final line
  `Updated 30 s ago`.

### Click menu

```
Session (5h)     25%  ▓▓░░░░░░░░   resets in 4h 22m
Weekly · all     26%  ▓▓▓░░░░░░░   resets Sun 23:59
Weekly · Fable   17%  ▓▓░░░░░░░░   resets Mon 00:00
────────────────────────────────────
Updated 30 s ago              Refresh
Open usage page (claude.ai)
────────────────────────────────────
✓ Launch at login
  Refresh interval ▸ 60 s / 90 s / 3 min / 5 min
────────────────────────────────────
Quit
```

- Limit rows are plain menu items (disabled, non-clickable) with a monospaced
  font. Bar is 10 characters of `▓`/`░`, rounded to the nearest 10 %.
- Reset text: if the reset is within 24 h, `resets in Xh Ym`; otherwise
  `resets <weekday> HH:mm` in local time. If `resets_at` is null, omit.
- "Refresh" triggers an immediate fetch. "Updated … ago" is recomputed each
  time the menu opens.
- "Open usage page" opens `https://claude.ai/settings/usage` in the default browser.
- "Launch at login" toggles `SMAppService.mainApp` and reflects its real state
  each time the menu opens.
- "Refresh interval" is a submenu with a check mark on the current value;
  stored in `UserDefaults`.

### Refresh triggers

- Timer at the configured interval.
- App launch (immediately).
- Wake from sleep (`NSWorkspace.didWakeNotification`).
- Manual "Refresh".
- After a 401, one automatic retry with a freshly read token (see errors).

### Error handling

The last good snapshot stays on screen. Errors add a `⚠︎` segment at the end
of the title and explain themselves in the tooltip and as a disabled line at
the top of the menu.

| Situation | Title | Message |
|---|---|---|
| Keychain item missing / not parseable, and no credentials file | `⚠︎ not signed in` (no numbers yet) | Not signed in to Claude Code. Run `claude` in a terminal and log in. |
| HTTP 401 | re-read token, retry once; if still 401: numbers + `⚠︎` | Token expired. Open Claude Code to refresh it. |
| HTTP 429 | numbers + `⚠︎` | Rate limited. Next refresh in 5 min. (One-off 5-minute backoff, then normal interval.) |
| Other HTTP error / decode failure | numbers + `⚠︎` | Usage API error (HTTP 500). Last updated 3 min ago. |
| Network unreachable / timeout (10 s) | numbers + `⚠︎` | Offline. Last updated 3 min ago. |
| First fetch failing (no numbers yet) | `⚠︎` | as above |

Once a fetch succeeds the `⚠︎` disappears.

## Structure

Swift Package with a library target for all logic (no AppKit), an executable
target for the menu bar UI, and one test target that depends only on the
library.

```
Package.swift
Sources/ClaudeUsageBarCore/     library, no AppKit — everything here is unit-tested
  Models.swift                UsageBucket, UsageSnapshot, FetchState, UsageError.
  CredentialStore.swift       Reads and parses the token (Keychain via `security`, then
                              ~/.claude/.credentials.json). Injectable command runner for tests.
  UsageResponseDecoder.swift  JSON → UsageSnapshot (limits[] first, top-level fallback).
  UsageAPIClient.swift        Builds the request, performs it with URLSession, maps HTTP
                              status to UsageError. Injectable URLSession for tests.
  Formatting.swift            Title segments + severity, tooltip, menu rows, countdown text,
                              bar string, error messages. Pure functions. Colors are a
                              `Severity` enum here; the app maps them to NSColor.
  UsagePoller.swift           Timer, 401 retry, 429 backoff, publishes FetchState on the
                              main actor. Token provider and fetcher are injected closures.
Sources/ClaudeUsageBar/         executable, AppKit
  main.swift                  NSApplication as .accessory (no Dock icon). Builds the object
                              graph, registers the wake-from-sleep observer, starts the poller.
  StatusItemController.swift  Owns the NSStatusItem. Renders title, tooltip, menu from
                              a FetchState. Handles menu actions.
  Preferences.swift           Refresh interval (UserDefaults) and launch-at-login (SMAppService).
Tests/ClaudeUsageBarTests/
  Fixtures/usage-response.json  the response above (no token)
  UsageAPIClientTests.swift   decode fixture → 3 buckets with correct labels/percents/dates;
                              tolerates nulls/unknown fields; falls back to five_hour/seven_day.
  CredentialStoreTests.swift  parses the JSON blob; missing item → .notSignedIn; file fallback.
  FormattingTests.swift       title layout, threshold colors, label derivation (incl. collisions),
                              countdown/weekday text, bar rounding.
  UsagePollerTests.swift      401 → one retry; 429 → backoff; error keeps last snapshot.
scripts/bundle-app.sh         swift build -c release, assemble ClaudeUsageBar.app
                              (Info.plist: LSUIElement=true, bundle id, version), ad-hoc codesign.
Makefile                      build | test | run | install (copies to /Applications) | clean
README.md                     what it is, screenshot, install, how it gets the token, privacy note
LICENSE                       MIT
```

### Key types

```swift
struct UsageBucket: Equatable {
  enum Kind: Equatable { case session, weeklyAll, weeklyScoped(model: String?), other(String) }
  let kind: Kind
  let percent: Int
  let resetsAt: Date?
}

struct UsageSnapshot: Equatable {
  let buckets: [UsageBucket]   // in display order
  let fetchedAt: Date
}

enum UsageError: Error, Equatable {
  case notSignedIn, unauthorized, rateLimited, http(Int), decoding, offline
}

enum FetchState: Equatable {
  case idle
  case loaded(UsageSnapshot)
  case failed(UsageError, last: UsageSnapshot?)
}
```

`FetchState` is the only thing the UI reads. Formatting is a set of pure
functions from `FetchState` (+ `Date()` for "ago"/countdown) to strings and
colors, so all of it is unit-testable without AppKit windows.

## Testing

- `swift test` runs everything under `Tests/`. All logic that is not literally
  AppKit rendering lives in pure functions or in types with injectable
  dependencies (URLSession via `URLProtocol` stub, command runner closure,
  clock closure).
- Manual check: `make run` shows the item in the menu bar with live numbers;
  hover shows the tooltip; each menu item works; sleeping/waking the Mac
  triggers a refresh; quitting Claude Code's session does not break anything.

## Build, install, distribution

- `make build` → `swift build -c release`.
- `make install` → runs `scripts/bundle-app.sh`, which lays out
  `build/ClaudeUsageBar.app/Contents/{MacOS,Resources,Info.plist}`, ad-hoc
  signs it (`codesign --force --sign -`), and copies it to `/Applications`.
- Ad-hoc signing is enough for a locally built app and for `SMAppService`
  launch-at-login. Downloaded zips would need
  `xattr -dr com.apple.quarantine`; the README says so. Notarized releases and
  a Homebrew cask are later work.

## Out of scope for v1

- Floating always-on-top overlay window (the data layer is separate; this is
  an additive toggle later).
- Other LLM providers (repo name is generic on purpose; models are Claude-only
  for now).
- Notifications when a limit crosses a threshold.
- Extra usage / spend display.
- Any token refresh or Keychain writes.
- Signed/notarized release builds.
