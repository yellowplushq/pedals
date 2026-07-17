#!/usr/bin/env bash
# Pedals end-to-end test (ARCHITECTURE.md "Testing").
#
#   local relay :8787  →  `pedals serve`  →  headless Node client pairs,
#   creates a session, runs printf, asserts the marker arrives decrypted.
#   Then the iOS simulator: build, install, `simctl openurl` the pairing
#   URL, and screenshot the rendered terminal to .artifacts/ios-terminal.png.
#
# Requires: Xcode (iPhone 17 Pro simulator), xcodegen, node >= 22.
# Exits 0 only if every stage passes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/.artifacts"
RELAY_PORT="${RELAY_PORT:-8787}"
SIM_DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="app.yellowplus.pedals"
MARKER="pedals-e2e-$$"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mkdir -p "$ARTIFACTS"
PEDALS_HOME="$(mktemp -d /tmp/pedals-e2e.XXXXXX)"
export PEDALS_HOME

log() { printf '\033[1;36m[e2e]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[e2e] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

RELAY_PID=""
DAEMON_PID=""
cleanup() {
  [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>/dev/null || true
  [[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null || true
  rm -rf "$PEDALS_HOME"
}
trap cleanup EXIT

# ---- 1. local relay ------------------------------------------------------

log "installing relay deps"
(cd "$ROOT/relay" && npm install --no-audit --no-fund --silent)

log "starting relay on :$RELAY_PORT"
PORT="$RELAY_PORT" node "$ROOT/relay/server.mjs" &
RELAY_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$RELAY_PID" 2>/dev/null || fail "relay exited during startup"
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$RELAY_PORT/healthz" >/dev/null || fail "relay /healthz not responding"
log "relay is up"

# ---- 2. desktop daemon ---------------------------------------------------

log "building pedals daemon (swift build)"
swift build --package-path "$ROOT/desktop/PedalsDaemon" >/dev/null
PEDALS_BIN="$(swift build --package-path "$ROOT/desktop/PedalsDaemon" --show-bin-path)/pedals"
[[ -x "$PEDALS_BIN" ]] || fail "daemon binary not found at $PEDALS_BIN"

log "starting pedals serve (PEDALS_HOME=$PEDALS_HOME)"
"$PEDALS_BIN" serve --relay "ws://127.0.0.1:$RELAY_PORT" &
DAEMON_PID=$!
for _ in $(seq 1 50); do
  [[ -S "$PEDALS_HOME/pedals.sock" && -f "$PEDALS_HOME/pairing.json" ]] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "daemon exited during startup"
  sleep 0.2
done
[[ -S "$PEDALS_HOME/pedals.sock" ]] || fail "daemon control socket never appeared"

PAIR_URL="$(node -e '
  const fs = require("node:fs");
  process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).url);
' "$PEDALS_HOME/pairing.json")"
[[ "$PAIR_URL" == pedals://pair?* ]] || fail "unexpected pairing URL: $PAIR_URL"
log "pairing URL: $PAIR_URL"

# ---- 3. headless protocol client -----------------------------------------

log "running headless client (marker: $MARKER)"
node "$ROOT/relay/test/client.mjs" --pair "$PAIR_URL" --expect "$MARKER" --keep --timeout 30 \
  || fail "headless client did not receive the marker decrypted end-to-end"
log "headless E2E passed: marker arrived decrypted"

# ---- 4. iOS simulator ----------------------------------------------------

log "generating Xcode project (xcodegen)"
(cd "$ROOT/ios" && xcodegen generate --quiet)

log "resolving simulator '$SIM_DEVICE'"
SIM_UDID="$(xcrun simctl list devices available --json | node -e '
  const data = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
  const all = Object.values(data.devices).flat();
  const match = all.find((d) => d.name === process.argv[1]);
  if (!match) process.exit(1);
  process.stdout.write(match.udid);
' "$SIM_DEVICE")" || fail "no available simulator named '$SIM_DEVICE'"

xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
log "simulator booted ($SIM_UDID)"

log "building iOS app (xcodebuild)"
xcodebuild \
  -project "$ROOT/ios/Pedals.xcodeproj" \
  -scheme Pedals \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$ARTIFACTS/dd-ios" \
  -quiet \
  build \
  || fail "iOS build failed"

APP_PATH="$ARTIFACTS/dd-ios/Build/Products/Debug-iphonesimulator/Pedals.app"
[[ -d "$APP_PATH" ]] || fail "built app not found at $APP_PATH"

log "installing and pairing the app"
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM_UDID" "$APP_PATH"
xcrun simctl openurl "$SIM_UDID" "$PAIR_URL"

# Poll the daemon until the iOS client is connected over the relay, then give
# the terminal a moment to replay + render before taking the screenshot.
log "waiting for the iOS client to connect"
CLIENT_STATE="none"
for _ in $(seq 1 60); do
  CLIENT_STATE="$("$PEDALS_BIN" status | sed -n 's/^client: //p')"
  [[ "$CLIENT_STATE" == "connected" ]] && break
  sleep 0.5
done
[[ "$CLIENT_STATE" == "connected" ]] || fail "iOS client never connected to the daemon"
log "iOS client connected; waiting for terminal render"
sleep 5

SCREENSHOT="$ARTIFACTS/ios-terminal.png"
xcrun simctl io "$SIM_UDID" screenshot "$SCREENSHOT" >/dev/null
[[ -s "$SCREENSHOT" ]] || fail "screenshot is empty"
log "screenshot written to $SCREENSHOT"

log "E2E passed"
