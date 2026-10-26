# gnotify

## Workflow exception: local git, not Solari

This repo builds a local macOS app, so it is an exception to the global
"Solari first" rule. Changes are made in the local checkout, verified with
`flutter analyze`, `flutter test` and a build, then committed on a branch and
opened as a PR with `gh`. Do not route changes through Solari here.

Release builds run locally (`./build_release.sh`): the script bumps the patch
version in `pubspec.yaml`, signs with the Developer ID identity on this Mac,
and notarizes. The version bump, the `vX.Y.Z` tag and the GitHub release are
created from the local checkout. Jason merges PRs himself.

## Keep

- STATUS.md at the repo root, updated in every change that touches files
  (global rule). The repo is public: nothing in it you would not put in README.
- Debug builds are ad hoc signed, so launching one triggers a Keychain access
  prompt for the token; avoid launching debug builds unless the UI needs a look.
