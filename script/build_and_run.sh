#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="VideoTagManager"
BUNDLE_ID="com.larryisthere.video-tag-manager"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_project_build_instances() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "$APP_BINARY" || true)
}

find_external_instance() {
  local pid
  local command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ -n "$command" && "$command" != "$APP_BINARY"* ]]; then
      echo "$pid"
      return 0
    fi
  done < <(pgrep -x "$APP_NAME" || true)
}

stop_project_build_instances
EXTERNAL_INSTANCE_PID="$(find_external_instance)"

xcodebuild \
  -project "$ROOT_DIR/VideoTagManager.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

# Cloud-backed local folders can add Finder metadata to the bundle while Xcode
# writes it. Remove that metadata before applying a development-only ad-hoc
# signature with the app's sandbox entitlements.
/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$ROOT_DIR/Config/VideoTagManager.entitlements" \
  "$APP_BUNDLE"

open_app() {
  if [[ -n "$EXTERNAL_INSTANCE_PID" ]]; then
    echo "$APP_NAME is already running under another launcher (PID $EXTERNAL_INSTANCE_PID)."
    echo "Build completed; launch skipped to preserve the active Xcode debug session."
    return 0
  fi
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_window() {
  if [[ -n "$EXTERNAL_INSTANCE_PID" ]]; then
    echo "Window verification skipped while the Xcode debug session is active."
    return 0
  fi
  for _ in {1..20}; do
    local pid
    local window_count
    pid="$(pgrep -f "$APP_BINARY" | tail -n 1)"
    if [[ -n "$pid" ]]; then
      window_count="$(/usr/bin/osascript -e "tell application \"System Events\" to tell first application process whose unix id is $pid to count windows" 2>/dev/null || true)"
    fi
    if [[ "${window_count:-0}" =~ ^[0-9]+$ ]] && [[ "${window_count:-0}" -gt 0 ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "$APP_NAME launched without creating a visible window" >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    if [[ -n "$EXTERNAL_INSTANCE_PID" ]]; then
      echo "$APP_NAME is already running under another launcher (PID $EXTERNAL_INSTANCE_PID)." >&2
      echo "Stop the active Xcode debug session before starting LLDB from this script." >&2
      exit 1
    fi
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_window
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
