# Status
_Last updated: 2026-10-23, waiting on org approval of the org-owned fine-grained PAT; app at 1.0.9_

## Current state
- Released: v1.0.9, notarized DMG + zip on GitHub Releases. Site live at
  https://gnotify.dev (Pages from `main` `/docs`, custom domain, HTTPS enforced).
- Polling: one GraphQL `ISSUE_ADVANCED` request per tick covers both tabs with
  requested reviewers and latest reviews; cost 1–2 of a 5,000/hour budget.
  Rate-limit backoff (60 s doubling to 15 min), 10 s debounce on popover opens.
- Announced PRs survive blank search results (forgotten after 5 consecutive
  misses). Copilot announced once per PR. Persisted ids are at scheme 3.
- Token lives in the macOS Keychain (`KeychainStore` in AppDelegate), other
  settings in sandboxed UserDefaults. Local log at
  `Application Support/gnotify.log`, opened from Settings → Log.
- This Mac runs 1.0.9 against a personal-owner token (sees only public batchco
  PRs; `toReview=0` is expected here). Work laptop runs 1.0.8 with a token that
  lacks Members: Read, so team review requests come back as
  "Resource not accessible by personal access token" (harmless, team chips missing).

## Recent decisions
- GraphQL single request instead of REST searches + per-PR calls: the REST
  pattern tripped GitHub's secondary (burst) limits at 30 s polling.
- 5-poll grace before forgetting an announced PR: the search index returns a
  blank result ~1.5% of polls, and forgetting on one miss replayed everything.
- Copilot once per PR, not per review: it re-reviews on every push.
- Token moved to Keychain: it was plaintext in the prefs plist.
- Popover hosts the Flutter view in a container VC and forwards left-click
  events via a local monitor: AppKit drops popover clicks under
  Reduce Transparency (flutter/flutter#115015). Confirmed on macOS 26.
- Release script bumps the patch version; build number stays at 9.
- Site: Fraunces + IBM Plex Mono, dark/light, no JS beyond the footer year;
  mock popover data is fictional so nothing from a real org appears.

## Known issues
- Debug builds are ad hoc signed, so each rebuild triggers a Keychain access
  prompt; release builds (Developer ID) do not.
- Copilot detection (`login contains "copilot"`) not yet confirmed against a
  live Copilot review in the work org.
- Footer says "All rights reserved" while the repo is MIT; user is fine with it.
- The site's OG image is commented out in `docs/index.html` pending a real
  screenshot.

## Open threads
- Org owner approval of the new org-owned fine-grained PAT (ripberge) with
  Pull requests: Read + Members: Read. Until then the work laptop shows the
  Members: Read warning (once on 1.0.9) and team chips are missing.
- Work laptop should be upgraded 1.0.8 → 1.0.9 for the footer hint.
- Merged feature branches are still on origin and can be deleted.
