# OpenRouter credits in the menu bar — design

Date: 2026-08-21
Status: approved and implemented

## What it adds

A fourth segment in the menu bar title showing the user's remaining OpenRouter
credit balance, next to the existing Claude limits:

```
5h 25% · W 26% · F 17% · OR $12.34
```

The click menu gains a row (`OpenRouter  $12.34 remaining · used $487.66 of
$500.00`) and a link to openrouter.ai's credits page. The hover tooltip gains a
balance line. Macs without an OpenRouter key see no change at all.

## Constraints and decisions

| Decision | Choice | Why |
|---|---|---|
| Where the key comes from | Read `OPENROUTER_API_KEY` from shell config files, read-only | The user chose reusing existing config over a paste-a-key UI. Matches how the app already reuses Claude Code's login without owning credentials. |
| File order | `~/.zshrc`, `~/.zshenv`, `~/.zprofile`, `~/.bashrc`, `~/.bash_profile`, `~/.profile`; first file with a usable line wins; within a file the last assignment wins | Most likely location first (zsh is the macOS default); last-assignment-wins mirrors shell semantics. |
| Unresolvable values | Lines whose value contains `$` are skipped | The app cannot expand shell variables; a literal `$SECRET` is never a valid key. |
| Data source | `GET https://openrouter.ai/api/v1/credits`, Bearer auth, 10 s timeout | Returns `{"data":{"total_credits":…,"total_usage":…}}`. Verified 2026-08-21 against a live account. Remaining = purchased − used. |
| Polling | A second `UsagePoller` instance on the same user-chosen interval | `UsagePoller` and `FetchState` became generic over the snapshot type, so the tested retry/backoff/staleness logic is shared instead of duplicated. Menu-open, wake, and Refresh trigger both pollers. |
| Color thresholds | Amber below $5 remaining, red below $1 | Dollars, not percents, so the Claude 50 %/80 % thresholds do not apply. Values confirmed by the user. |
| No key found | The segment, menu row, and tooltip line are simply absent | OpenRouter is optional; a missing key is not an error worth a permanent ⚠︎. |
| Errors | Keep the last balance, append `⚠︎`, explain in the menu and tooltip | Same behavior as the Claude segments. |
| Negative balances | Displayed as `$0.00`, colored red | `total_usage` can overshoot `total_credits` slightly; a negative dollar figure reads as a bug. |

## Structure

New in `Sources/ClaudeUsageBarCore` (all unit-tested, no AppKit):

- `OpenRouterKeyStore` — finds the key in shell config files. Handles
  `export`, quotes, trailing comments; skips commented-out lines.
- `OpenRouterAPIClient` — fetches and decodes the credits endpoint into a
  `CreditsSnapshot` (`totalCredits`, `totalUsage`, `remaining`, `fetchedAt`).
- `TimestampedSnapshot` — the protocol both snapshot types share so
  `UsagePoller<Snapshot>` and `FetchState<Snapshot>` work for either provider.
- `Formatting` additions — `severity(forRemainingCredits:)`, `creditsText`,
  `openRouterTitleSegments`, `openRouterMenuLine`, `openRouterErrorMessage`,
  `openRouterTooltipLines`, and a `credits:` parameter on `tooltip` that puts
  the balance line before "Updated N ago".

`Sources/ClaudeUsageBar` (AppKit glue, untested by convention) wires a second
poller through `StatusItemController` and `main.swift`: combined title
segments, combined tooltip, the menu row, the credits-page link, and both
pollers on every refresh trigger.
