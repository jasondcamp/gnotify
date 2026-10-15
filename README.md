# gnotify

macOS menubar app that watches GitHub and tells you when a pull request needs your review.

- **Notifications** when a PR opens with a review request for you or one of your teams.
- **Badge** on the menubar icon with the number of PRs currently waiting on you.
- **List** of those PRs in a popover, on a **To review** tab; click one to open
  it in the browser. Your own PRs never appear here.
- **My PRs** tab: every open PR you authored in the org, with Approved /
  Changes requested / Awaiting review / Draft and who said or was asked what.
- **Approval alerts** when a PR you opened in the org gets an approving review.
- Both kinds of notification have a toggle in Settings. With both off it works
  as a plain dashboard: list and badge only.

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

Every poll runs one GitHub search per target:

```
is:pr is:open draft:false org:<org> review-requested:<user>
is:pr is:open draft:false org:<org> team-review-requested:<org>/<team>
```

Results are merged by PR id. Because `review-requested:<user>` also matches
requests sent to a team the user belongs to, each PR is then read once (cached
until it changes) and the chips show only the targets it names directly. The
count is pushed to the menubar, and any PR not seen before gets a notification. The My PRs tab comes from one more search:

```
is:pr is:open org:<org> author:@me
```

Each of those is read once (cached until it changes) for its reviews and
outstanding requests. A PR whose state becomes Approved is announced once, naming
the approvers. The badge and list are unaffected; they only ever count reviews
waiting on you. Once you submit a review GitHub drops the review
request, so the PR falls off the list; if someone re-requests you, it notifies again.

Settings and the token are stored in the app's sandboxed `UserDefaults`.

## License

[MIT](LICENSE)
