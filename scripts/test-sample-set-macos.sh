#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/SecretBox"
DERIVED_DATA_PATH="$ROOT_DIR/.derived"
DEVELOPER_DIR_PATH="/Applications/Xcode.app/Contents/Developer"
TARGET_TEST="SecretBoxTests/SecretBoxAppModelTests/testDiverseFiftySampleSetPersistAndClassify"

COMMON_ARGS=(
  -project SecretBox.xcodeproj
  -scheme SecretBox
  -destination "platform=macOS"
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -derivedDataPath "$DERIVED_DATA_PATH"
)

run_xcodebuild() {
  local label="$1"
  shift

  local log_file
  log_file="$(mktemp /tmp/secretbox-sample-set.XXXXXX.log)"

  echo "[$label]"
  set +e
  (
    cd "$PROJECT_DIR"
    DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild "${COMMON_ARGS[@]}" "$@"
  ) 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  set -e

  if rg -q "Sandbox restriction|testmanagerd.control was invalidated|Failed to establish communication with the test runner" "$log_file"; then
    echo
    echo "macOS XCTest was blocked by the current environment."
    echo "Run this script from a normal local Terminal or Xcode session."
    rm -f "$log_file"
    exit 2
  fi

  if [[ $status -ne 0 ]]; then
    echo
    echo "xcodebuild failed for: $label"
    rm -f "$log_file"
    return "$status"
  fi

  rm -f "$log_file"
}

run_xcodebuild "1/2 Build for testing" build-for-testing
run_xcodebuild "2/2 Run 50-sample classifier regression" test "-only-testing:$TARGET_TEST"

echo
echo "50-sample macOS classifier regression passed."
