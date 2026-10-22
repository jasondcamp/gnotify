# gnotify

macOS menubar app that watches GitHub and tells you when a pull request needs your review.

- **Notifications** when a PR opens with a review request for you or one of your teams.
- **Badge** on the menubar icon with the number of PRs currently waiting on you.
- **List** of those PRs in a popover, on a **To Review** tab; click one to open
  it in the browser. Your own PRs never appear here.
- **My PRs** tab: every open PR you authored in the org, with Approved /
  Changes requested / Awaiting review / Draft and who said or was asked what.
- **Approval alerts** when a PR you opened in the org gets an approving review.
- **Copilot alerts** when Copilot code review finishes on a PR you opened. The
  My PRs tab also shows "Copilot reviewing" / "Copilot reviewed".
- Every kind of notification has a toggle in Settings. With all of them off it
  works as a plain dashboard: list and badge only.

Built with Flutter, following the same layout as the twickets menubar app.

## Setup

1. Launch the app and open Settings (first launch opens it automatically).
2. Paste a GitHub token.
   - **Classic PAT**: scopes `repo` and `read:org`.
   - **Fine-grained PAT**: set **Resource owner** to the organization (not your
     personal account), grant **Pull requests: Read** on the repos to watch, and
     **Members: Read** on the org for team queries. If the org restricts
     fine-grained tokens, an org owner has to approve it. A token issued under
     your personal account can read the org's metadata but every org-scoped
     search returns 422 "The listed users and repositories cannot be searched".
3. Enter the organization to watch.
4. Add one or more targets: usernames, or teams written as `org/team-slug`.
   "Add me" resolves the token's own user and adds it.
5. Save. The app polls on the configured interval (default 60s).

Right-click the menubar icon for Refresh, Settings, Launch at Login and Quit.

## Development

```bash
./run.sh            # flutter run -d macos with hot reload
./build.sh          # release build copied to /Applications/gnotify.app
./build_release.sh  # signed, notarized zip + DMG on the Desktop
```

See [APP.md](APP.md) for the signing and notarization details.

## How it works

Every poll is **one GraphQL request** (a second or third only if the org has
more than 100 matching PRs). The search covers both tabs at once:

```
org:<org> is:pr is:open ((author:@me) OR (-author:@me draft:false (review-requested:<user> OR team-review-requested:<org>/<team> ...)))
```

and the same request returns each PR's requested reviewers and every
reviewer's latest review, so there are no follow-up calls per PR. GraphQL has
its own 5,000 points/hour budget; a poll costs 1. The remaining budget shows
in the popover footer.

Review-request chips show only the targets a PR names directly, because
`review-requested:<user>` also matches requests sent to a team the user
belongs to. The To Review count is pushed to the menubar, and any PR not seen
before gets a notification. A PR whose state becomes Approved, or that picks
up a Copilot review, is announced once.

If GitHub answers with a rate limit, the app waits as long as it was told (at
least a minute, doubling on repeat, capped at 15 minutes) before trying again,
and popover opens within 10 seconds of the last poll do not trigger another.

A local log (`Settings → Log`) records every poll, its cost, notifications
sent, and any GitHub errors. The token is never written to it.

The token is stored in the macOS Keychain. The remaining settings live in the
app's sandboxed `UserDefaults`. A token saved by a build before 1.0.6 is moved
into the Keychain on first launch and removed from the plist.

## License

[MIT](LICENSE)
