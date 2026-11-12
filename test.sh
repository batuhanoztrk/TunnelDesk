#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tunneldesk-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
chmod +x "$PROJECT_DIR/Tests/fake-kubectl.py"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/ProfileStore.swift" \
  "$PROJECT_DIR/Sources/KubeconfigStore.swift" \
  "$PROJECT_DIR/Sources/Subprocess.swift" \
  "$PROJECT_DIR/Sources/TunnelEngine.swift" \
  "$PROJECT_DIR/Tests/IntegrationTests.swift" \
  "$PROJECT_DIR/Tests/ManagedKubeconfigTests.swift" \
  -o "$BUILD_DIR/IntegrationTests"
"$BUILD_DIR/IntegrationTests" "$PROJECT_DIR"
SPARKLE_DIR="$(bash "$PROJECT_DIR/scripts/fetch-sparkle.sh")"
TUNNELDESK_SPARKLE_DIR="$SPARKLE_DIR" python3 -m unittest discover -s "$PROJECT_DIR/Tests" -p 'test_updates.py' -v
