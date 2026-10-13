#!/bin/bash
# Dev build: release binary installed to /Applications (ad hoc signed).
cd "$(dirname "$0")"

flutter build macos --release \
  && rm -rf "/Applications/gnotify.app" \
  && cp -r "build/macos/Build/Products/Release/gnotify.app" "/Applications/gnotify.app"

echo ""
echo "Installed to /Applications/gnotify.app"
