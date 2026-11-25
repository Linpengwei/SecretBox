#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/SecretBox"
DERIVED_DATA_PATH="$ROOT_DIR/.derived"
DEVELOPER_DIR_PATH="/Applications/Xcode.app/Contents/Developer"

COMMON_ARGS=(
  -project SecretBox.xcodeproj
  -scheme SecretBox
  -destination "platform=macOS"
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -derivedDataPath "$DERIVED_DATA_PATH"
)

# Every UI test in SecretBoxUITests, spelled out so each one is retried on its
# own and a test that stops running is visible in review.
UI_TESTS=(
  "SecretBoxUITests/SecretBoxUITests/testLoginFlowOpensDashboard"
  "SecretBoxUITests/SecretBoxUITests/testSearchFiltersSeededRecords"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarSmokeFlowCanSaveAndOpenDashboard"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarPreviewCanEditAndSaveLocally"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarPreviewFieldOverrideCanSaveEditedHost"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarPreviewFieldsCanExpand"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarSearchCopiesSeededPasswordOnReturn"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarSearchOpensRecordInDashboardOnCommandReturn"
  "SecretBoxUITests/SecretBoxUITests/testMenuBarCaptureSavesWithCommandReturn"
  "SecretBoxUITests/SecretBoxUITests/testQuickCaptureSheetCanOpen"
  "SecretBoxUITests/SecretBoxUITests/testCaptureSaveSearchDetailCopyFlow"
  "SecretBoxUITests/SecretBoxUITests/testCaptureWithOTPAuthShowsLiveCodeAndCopies"
  "SecretBoxUITests/SecretBoxUITests/testReadOnlyPermissionLocksEditing"
  "SecretBoxUITests/SecretBoxUITests/testSettingsSheetOpensAndCloses"
)

SAMPLE_SET_TEST="SecretBoxTests/SecretBoxAppModelTests/testDiverseFiftySampleSetPersistAndClassify"

# UI_TESTS once listed 3 of 14 tests, so most of the suite never ran in the
# documented regression. Fail fast when the list and the test file disagree.
assert_every_ui_test_is_listed() {
  local declared
  declared="$(grep -cE '^[[:space:]]*func test' "$PROJECT_DIR/SecretBoxUITests/SecretBoxUITests.swift")"
  if [[ "$declared" -ne "${#UI_TESTS[@]}" ]]; then
    echo "UI_TESTS lists ${#UI_TESTS[@]} tests but SecretBoxUITests.swift declares $declared."
    echo "Add every new UI test to UI_TESTS in scripts/test-macos.sh."
    exit 1
  fi
}

run_xcodebuild() {
  local label="$1"
  shift

  local log_file
  log_file="$(mktemp /tmp/secretbox-xcodebuild.XXXXXX.log)"

  echo "[$label]"
  set +e
  (
    cd "$PROJECT_DIR"
    DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild "${COMMON_ARGS[@]}" "$@"
  ) 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  set -e

  if rg -q "Sandbox restriction|testmanagerd.control was invalidated" "$log_file"; then
    echo
    echo "macOS XCTest was blocked by the current environment."
    echo "Run this script from a normal local Terminal or Xcode session, not inside a restricted sandbox."
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

run_ui_test_with_retry() {
  local test_identifier="$1"
  local attempt=1
  local max_attempts=2
  local log_file

  while [[ $attempt -le $max_attempts ]]; do
    log_file="$(mktemp /tmp/secretbox-ui-test.XXXXXX.log)"
    echo "[UI $(basename "$test_identifier")] attempt $attempt/$max_attempts]"

    set +e
    (
      cd "$PROJECT_DIR"
      DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild "${COMMON_ARGS[@]}" test-without-building "-only-testing:$test_identifier"
    ) 2>&1 | tee "$log_file"
    local status=${PIPESTATUS[0]}
    set -e

    if rg -q "Sandbox restriction|testmanagerd.control was invalidated" "$log_file"; then
      echo
      echo "macOS UI automation was blocked by the current environment."
      echo "Run this script from a normal local Terminal or Xcode session, not inside a restricted sandbox."
      rm -f "$log_file"
      exit 2
    fi

    if [[ $status -eq 0 ]]; then
      rm -f "$log_file"
      return 0
    fi

    if rg -q "Timed out while enabling automation mode" "$log_file" && [[ $attempt -lt $max_attempts ]]; then
      echo "UI automation host timed out. Retrying once."
      rm -f "$log_file"
      attempt=$((attempt + 1))
      sleep 2
      continue
    fi

    echo
    echo "UI test failed: $test_identifier"
    rm -f "$log_file"
    return "$status"
  done
}

assert_every_ui_test_is_listed

run_xcodebuild "1/4 Build for testing" build-for-testing
# Unit suites: model (incl. the 50-sample regression), TOTP engine, view
# snapshots. Everything after the build step runs without rebuilding.
run_xcodebuild "2/4 Run unit tests" test-without-building \
  -only-testing:SecretBoxTests/SecretBoxAppModelTests \
  -only-testing:SecretBoxTests/TOTPEngineTests \
  -only-testing:SecretBoxTests/ViewSnapshotTests
run_xcodebuild "3/4 Run 50-sample classifier regression" test-without-building "-only-testing:$SAMPLE_SET_TEST"

echo "[4/4 Run UI tests (${#UI_TESTS[@]})]"
for test_identifier in "${UI_TESTS[@]}"; do
  run_ui_test_with_retry "$test_identifier"
done

echo
echo "All macOS app tests passed."
