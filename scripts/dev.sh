#!/usr/bin/env bash
# Manual + automatable acceptance helpers for Local Loom milestones.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

case "${1:-}" in
  build)
    xcodegen generate
    xcodebuild -scheme LocalLoom -destination 'platform=macOS' -configuration Debug build
    ;;
  test)
    xcodegen generate
    xcodebuild -scheme LocalLoom -destination 'platform=macOS' test
    ;;
  open)
    xcodegen generate
    open LocalLoom.xcodeproj
    ;;
  *)
    echo "Usage: $0 {build|test|open}"
    exit 1
    ;;
esac
