#!/usr/bin/env bash
# Manual + automatable acceptance helpers for Specreel milestones.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

build_debug() {
  xcodegen generate -s project.yml
  xcodebuild \
    -project Specreel.xcodeproj \
    -scheme Specreel \
    -destination 'platform=macOS' \
    -configuration Debug \
    SYMROOT="${ROOT}/build" \
    build
}

case "${1:-}" in
  build)
    build_debug
    echo "App: ${ROOT}/build/Debug/Specreel.app"
    ;;
  run)
    build_debug
    open "${ROOT}/build/Debug/Specreel.app"
    ;;
  release)
    xcodegen generate -s project.yml
    xcodebuild \
      -project Specreel.xcodeproj \
      -scheme Specreel \
      -destination 'platform=macOS' \
      -configuration Release \
      SYMROOT="${ROOT}/build" \
      build
    echo "App: ${ROOT}/build/Release/Specreel.app"
    open "${ROOT}/build/Release/Specreel.app"
    ;;
  test)
    xcodegen generate -s project.yml
    xcodebuild -project Specreel.xcodeproj -scheme Specreel -destination 'platform=macOS' test
    ;;
  open)
    xcodegen generate -s project.yml
    open Specreel.xcodeproj
    ;;
  *)
    echo "Usage: $0 {build|run|release|test|open}"
    echo "  build    Debug → ./build/Debug/Specreel.app"
    echo "  run      build + open Debug app"
    echo "  release  Release → ./build/Release/Specreel.app + open"
    echo "  test     run unit/integration tests"
    echo "  open     generate project and open in Xcode"
    exit 1
    ;;
esac
