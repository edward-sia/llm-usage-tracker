# Install guide for AI coding agents

This file is a self-contained recipe for an AI coding agent (Claude Code,
Cursor, etc.) to build and install **Claude Usage Bar** on the user's Mac. A
human can follow it too. Do the steps in order and check each result before
moving on. Do not skip the verification steps.

## What you are installing

A native macOS menu bar app that shows the user's Claude subscription usage
(`5h 25% · W 26% · F 17%`) and, when the user has an OpenRouter API key in
their shell config, their remaining OpenRouter credits (`· OR $12.34`). It
reads the OAuth token that Claude Code already stores in the macOS Keychain
and polls Anthropic's usage endpoint; the OpenRouter key is read from files
like `~/.zshrc`. It is read-only: it never writes to the Keychain and never
refreshes the token.

## Safety rules for the agent

- **Never print, echo, or log the access token or the OpenRouter API key.**
  No step here requires reading either value; do not add one that does.
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
```

- macOS older than 14 → not supported; stop.
- `xcode-select -p` fails → tell the user to run `xcode-select --install`, wait
  for it to finish, then retry. (This needs the user; you cannot complete the
  GUI installer for them.)
- "claude-code: NOT signed in" → the app has nothing to read. Tell the user to
  install [Claude Code](https://claude.com/claude-code) and run `claude` to log
  in, then retry. (The file `~/.claude/.credentials.json` is an accepted
  fallback if they use the file store.)
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

This builds a release binary, wraps it in `ClaudeUsageBar.app`, ad-hoc signs
it, copies it to `/Applications`, kills any running copy, and launches the new
one.

## Step 4: Verify it is running

```bash
pgrep -x ClaudeUsageBar && echo "running"
codesign -dv /Applications/ClaudeUsageBar.app 2>&1 | grep -i "signature="   # Signature=adhoc
```

Then tell the user: **look at the top-right of your menu bar — you should see
your usage numbers** (e.g. `5h 25% · W 26% · F 17%`, plus `· OR $12.34` if
they have an OpenRouter key). It has no Dock icon by design. If the menu bar
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
/usr/bin/log show --last 6h --info --predicate 'subsystem == "dev.llm-usage-tracker.ClaudeUsageBar"' --style compact
```

Use the full path `/usr/bin/log` — plain `log` is a zsh builtin and fails with
"too many arguments". Add `AND process == "ClaudeUsageBar"` to the predicate to
exclude lines emitted by test runs. `log stream` with the same predicate
watches live.

Two categories: `claude` is the usage poller, `openrouter` the credits poller.
Example lines and how to read them:

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

Behavior worth knowing when interpreting logs: the usage endpoint is rate
limited per account and shared with the claude.ai usage page and the Claude
Code status line, so 429s can appear even when this app polls slowly. After a
429 the app waits out the server's `Retry-After` and skips menu-open fetches
meanwhile. On wake from sleep it waits a random 30–90 s before fetching so it
does not join the burst of every other Claude client refreshing at once. The
last good numbers live only in memory: if the app restarts while the account
is rate limited, the menu has nothing to show until the first successful fetch.

## Updating later

```bash
cd llm-usage-tracker
git pull
make install
```

## Uninstalling

```bash
pkill -x ClaudeUsageBar
rm -rf /Applications/ClaudeUsageBar.app
```

Also turn off Launch at login from the menu first if it was enabled. Removing
the app does not touch the Claude Code credentials it read.
