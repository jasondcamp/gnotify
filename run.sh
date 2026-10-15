#!/bin/bash
cd "$(dirname "$0")"

# Usage: ./run.sh   (runs the macOS app in debug mode with hot reload)
flutter pub get
flutter run -d macos
