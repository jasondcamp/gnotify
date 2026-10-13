# Building gnotify

gnotify is a Flutter menubar application (`LSUIElement = true`, no dock icon).
The Flutter view is hosted in an `NSPopover` attached to an `NSStatusItem`; all of
that lives in `macos/Runner/AppDelegate.swift`.

## Prerequisites

- Flutter SDK (>=3.10.7)
- Xcode with command line tools
- For release builds: a Developer ID Application certificate, a `notarytool`
  keychain profile, and `create-dmg` (`brew install create-dmg`)

## Development

```bash
./run.sh
```

## Local build (dev)

```bash
./build.sh
```

Produces a release build and copies it to `/Applications/gnotify.app`.

## Release build (signed + notarized)

```bash
./build_release.sh
```

The script bumps the build number, builds, archives with the Developer ID
identity and hardened runtime, submits to Apple with
`xcrun notarytool --keychain-profile notarytool`, staples the ticket and produces
`~/Desktop/gnotify.zip` and `~/Desktop/gnotify.dmg`.

To create the keychain profile once:

```bash
xcrun notarytool store-credentials notarytool \
  --apple-id "<apple id>" --team-id 6255B58MWB --password "<app-specific password>"
```

Generate an app-specific password at https://appleid.apple.com under
Sign-In and Security > App-Specific Passwords.

## App configuration

- **Menubar mode**: `LSUIElement = true` in `Info.plist`
- **Bundle id**: `com.jasoncamp.gnotify`
- **Entitlements**: app sandbox, network client
- **Popover size**: 420x520
- **Method channel**: `com.jasoncamp.gnotify/menubar`
  - Dart -> Swift: `updateBadge`, `updateTooltip`, `notify`, `openUrl`, `closePopover`
  - Swift -> Dart: `popoverOpened`, `openSettings`, `refresh`
- **Notifications**: `UNUserNotificationCenter`; clicking one opens the PR URL
- **Launch at login**: `SMAppService` (macOS 13+), prompted once on first launch
