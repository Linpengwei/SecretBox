#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/SecretBox"
DERIVED_DATA_PATH="$ROOT_DIR/.derived-ios"
DEVELOPER_DIR_PATH="/Applications/Xcode.app/Contents/Developer"

COMMON_ARGS=(
  -project SecretBox.xcodeproj
  -scheme SecretBox
  -destination "platform=iOS Simulator,name=iPhone 17"
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -derivedDataPath "$DERIVED_DATA_PATH"
)

SAMPLE_SET_TEST="SecretBoxTests/SecretBoxAppModelTests/testDiverseFiftySampleSetPersistAndClassify"

run_xcodebuild() {
  local label="$1"
  shift

  echo "[$label]"
  (
    cd "$PROJECT_DIR"
    DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild "${COMMON_ARGS[@]}" "$@"
  )
}

ensure_ios_runtime() {
  if ! DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcrun simctl list devices available | grep -q "iOS"; then
    echo "No iOS simulator runtime found. Install it with:"
    echo "  DEVELOPER_DIR=$DEVELOPER_DIR_PATH xcodebuild -downloadPlatform iOS"
    exit 2
  fi
}

ensure_ios_runtime

# Phase-1 iOS smoke chains: login / search / capture-save-search-copy /
# TOTP live code / read-only permission / settings. Menu-bar tests skip on
# iOS via XCTSkip inside the test class.
UI_SMOKE_TESTS=(
  "SecretBoxUITests/SecretBoxUITests/testLoginFlowOpensDashboard"
  "SecretBoxUITests/SecretBoxUITests/testSearchFiltersSeededRecords"
  "SecretBoxUITests/SecretBoxUITests/testQuickCaptureSheetCanOpen"
  "SecretBoxUITests/SecretBoxUITests/testCaptureSaveSearchDetailCopyFlow"
  "SecretBoxUITests/SecretBoxUITests/testCaptureWithOTPAuthShowsLiveCodeAndCopies"
  "SecretBoxUITests/SecretBoxUITests/testReadOnlyPermissionLocksEditing"
  "SecretBoxUITests/SecretBoxUITests/testSettingsSheetOpensAndCloses"
)

run_xcodebuild "1/4 Build for testing" build-for-testing
run_xcodebuild "2/4 Run unit tests" test -only-testing:SecretBoxTests/SecretBoxAppModelTests
run_xcodebuild "3/4 Run 50-sample classifier regression" test "-only-testing:$SAMPLE_SET_TEST"

echo "[4/4 Run iOS UI smoke tests]"
for ui_test in "${UI_SMOKE_TESTS[@]}"; do
  run_xcodebuild "UI $(basename "$ui_test")" test "-only-testing:$ui_test"
done

echo
echo "All iOS app tests passed."
