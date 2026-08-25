# Install guide for AI coding agents

This file is a self-contained recipe for an AI coding agent (Claude Code,
Cursor, etc.) to build and install **LLM Usage Bar** on the user's Mac. A
human can follow it too. Do the steps in order and check each result before
moving on. Do not skip the verification steps.

## What you are installing

A native macOS menu bar app that shows the user's Claude subscription usage
(`5h 25% · W 26% · F 17%` behind the Claude logo) and, when the credentials are
there to read, their ChatGPT usage (`5h 42% · W 8%` behind OpenAI's logo) and their
remaining OpenRouter credits (`$12.34` behind OpenRouter's logo).

Each provider reuses a login some other tool already made: the OAuth token Claude Code
stores in the macOS Keychain, the ChatGPT token Codex stores in `~/.codex/auth.json`,
and `OPENROUTER_API_KEY` from shell config files like `~/.zshrc`. It is read-only: it
never writes to the Keychain or to any of those files, and never refreshes a token.

## Safety rules for the agent

- **Never print, echo, or log any of the credentials** — the Claude Code access token,
  the ChatGPT token inside `~/.codex/auth.json`, or the OpenRouter API key. No step here
  requires reading any of those values; do not add one that does. The check below tests
  only whether the Codex auth file exists, and must stay that way.
- Only run the commands below (or their obvious equivalents). Do not add
  network calls, credential reads, or `sudo`.
- `make install` copies the app into `/Applications` and launches it. That is
  the intended outcome of this guide, so it is fine to run without asking. Do
  not take any other destructive or outward-facing action.

## Step 0: Preconditions

Run these and confirm before building. If any fails, tell the user how to fix
it and stop rather than guessing.

```bash
sw_vers -productVersion        # must be 14.0 or newer
xcode-select -p                # must print a path (Command Line Tools installed)
swift --version                # must succeed
security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1 && echo "claude-code: signed in" || echo "claude-code: NOT signed in"
test -f "${CODEX_HOME:-$HOME/.codex}/auth.json" && echo "chatgpt: codex login present" || echo "chatgpt: no codex login (optional)"
```

- macOS older than 14 → not supported; stop.
- `xcode-select -p` fails → tell the user to run `xcode-select --install`, wait
  for it to finish, then retry. (This needs the user; you cannot complete the
  GUI installer for them.)
- "claude-code: NOT signed in" → the app has nothing to read. Tell the user to
  install [Claude Code](https://claude.com/claude-code) and run `claude` to log
  in, then retry. (The file `~/.claude/.credentials.json` is an accepted
  fallback if they use the file store.)
- ChatGPT is optional. "no codex login" is fine — the ChatGPT segment simply does not
  appear. To get it, the user signs in to the ChatGPT desktop app, or runs `codex` and
  picks Sign in with ChatGPT. A Codex signed in with an API key instead of a ChatGPT
  account has no subscription to report, so it shows nothing either.
- OpenRouter is optional: no check needed. If the user has
  `OPENROUTER_API_KEY` exported in a shell config file, the app finds it on
  its own; if not, the OpenRouter segment simply does not appear.

## Step 1: Get the code

```bash
git clone https://github.com/edward-sia/llm-usage-tracker.git
cd llm-usage-tracker
```

If the repo is already cloned, `cd` into it and `git pull` instead.

## Step 2: Run the tests (optional but recommended)

```bash
swift test 2>&1 | grep -E "Executed [0-9]+ tests"
```

Expect `0 failures`. If tests fail, report the output and stop — do not install
a broken build.

## Step 3: Build and install

```bash
make install
```

This builds a release binary, wraps it in `LLMUsageBar.app`, ad-hoc signs
it, copies it to `/Applications`, kills any running copy, and launches the new
one.

## Step 4: Verify it is running

```bash
pgrep -x LLMUsageBar && echo "running"
codesign -dv /Applications/LLMUsageBar.app 2>&1 | grep -i "signature="   # Signature=adhoc
```

Then tell the user: **look at the top-right of your menu bar — you should see
your usage numbers** (e.g. `5h 25% · W 26% · F 17%` behind the Claude logo, plus
`5h 42% · W 8%` behind OpenAI's logo if they have a ChatGPT login, plus `$12.34` behind
OpenRouter's logo if they have an OpenRouter key). It has no Dock icon by design. If the menu bar
shows `⚠︎ not signed in`, Claude Code is not logged in (see Step 0). If it
shows numbers followed by `⚠︎`, the last refresh failed — hover or click the
item for the reason.

## Step 5: Offer Launch at Login

Tell the user they can turn on **Launch at login** from the app's click menu so
it starts with the Mac. (Programmatic toggling only works from the installed
`/Applications` copy, which is what Step 3 produced.)

## Debugging: reading the app's logs

The app writes one line to the macOS unified log for every fetch it makes (and
every fetch it deliberately skips). This is the first place to look when the
user asks "why does it say rate limited" or "why are my numbers stale".

```bash
/usr/bin/log show --last 6h --info --predicate 'subsystem == "dev.llm-usage-tracker.LLMUsageBar"' --style compact
```

Use the full path `/usr/bin/log` — plain `log` is a zsh builtin and fails with
"too many arguments". Add `AND process == "LLMUsageBar"` to the predicate to
exclude lines emitted by test runs. `log stream` with the same predicate
watches live.

Three categories: `claude` is the Claude usage poller, `chatgpt` the ChatGPT one, and
`openrouter` the credits poller. Example lines and how to read them:

```
fetch(start): ok (0.32s)
fetch(timer): HTTP 429 (retry-after 604s, 1 in a row) — next attempt in 604s (0.14s)
skip(menu-open): backing off after 429
wake: opportunistic fetch in 47s
```

- The word in parentheses after `fetch`/`skip` is what triggered it: `start`
  (app launch), `timer` (the refresh interval), `manual` (the Refresh menu
  item), `menu-open` (user opened the menu), `wake` (Mac woke from sleep).
- On a 429 the line shows the server's `Retry-After`, the consecutive-429
  count, and the wait the app actually chose (the header value clamped between
  5 minutes and 1 hour).
- Tokens, keys, and usage numbers are never logged.

Behavior worth knowing when interpreting logs: both usage endpoints are rate limited
per account and shared with other clients — Anthropic's with the claude.ai usage page
and the Claude Code status line, ChatGPT's with the ChatGPT app and `codex` — so 429s
can appear even when this app polls slowly. After a 429 the app waits out the server's
`Retry-After` and skips menu-open fetches meanwhile. On wake from sleep each poller
waits its own random 30–90 s before fetching so it does not join the burst of every
other client refreshing at once. The `chatgpt` poller additionally never polls faster than
once every 3 minutes, because its shortest window is five hours. That floor covers menu-open
and wake fetches as well, so glancing at the menu cannot pull its rate above one request every
3 minutes. The last good numbers live only in
memory: if the app restarts while an account is rate limited, the menu has nothing to
show for that provider until the first successful fetch.

## Updating later

```bash
cd llm-usage-tracker
git pull
make install
```

The app used to be called **Claude Usage Bar** and installed as
`ClaudeUsageBar.app`. If the user is upgrading from a build older than the
rename, tell them two things before you run `make install`:

- Turn off **Launch at login** from the old app's click menu first. macOS
  registers login items by bundle id, so an item pointing at the old bundle
  survives the rename and keeps trying to start an app that is no longer there.
- `make install` deletes `/Applications/ClaudeUsageBar.app` along with the new
  bundle it replaces. That is deliberate — leaving it would put two copies of
  the same app in the menu bar — but it is a deletion, so say it out loud
  rather than letting them discover it.

Their refresh interval and per-provider toggles carry over on first launch: the
app copies them from the old bundle id's preferences once. The menu bar item's
position is not carried over, so it may appear somewhere else along the bar.

## Uninstalling

```bash
make uninstall
```

That kills the running app and removes `/Applications/LLMUsageBar.app`, plus
`/Applications/ClaudeUsageBar.app` if a pre-rename copy is still there.

Also turn off Launch at login from the menu first if it was enabled. Removing
the app does not touch any of the credentials it read — the Claude Code Keychain item,
`~/.codex/auth.json`, and the shell config files are all left exactly as they were.
