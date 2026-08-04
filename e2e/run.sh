#!/usr/bin/env bash
set -euo pipefail

CLI_PATH=${1:?agentnest-cli path is required}
SERVER_PATH=${2:?license server path is required}

if [[ ! -x "$CLI_PATH" || ! -x "$SERVER_PATH" ]]; then
  echo "E2E requires compiled client and server binaries" >&2
  exit 1
fi

E2E_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agentnest-e2e.XXXXXX")
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$E2E_DIR"
}
trap cleanup EXIT

HOME_FIXTURE="$E2E_DIR/home"
DEFAULT_HOME="$HOME_FIXTURE/.codex"
DEEP_HOME="$HOME_FIXTURE/projects/.hidden/team/codex-home"
POSSIBLE_HOME="$HOME_FIXTURE/archive/.codex"
mkdir -p "$DEFAULT_HOME" "$DEEP_HOME" "$POSSIBLE_HOME"
printf '%s' '{"version":"e2e-default"}' > "$DEFAULT_HOME/version.json"
printf '%s' '{"version":"e2e-deep"}' > "$DEEP_HOME/version.json"
printf '%s' 'fixture-data' > "$DEFAULT_HOME/session.fixture"
ln "$DEFAULT_HOME/session.fixture" "$DEFAULT_HOME/session-hardlink.fixture"

SCAN_OUTPUT="$E2E_DIR/scan.json"
"$CLI_PATH" scan --root "$HOME_FIXTURE" --codex-home "$DEEP_HOME" > "$SCAN_OUTPUT"
CONFIRMED_COUNT=$(grep -c '"confidence" : "confirmed"' "$SCAN_OUTPUT" || true)
POSSIBLE_COUNT=$(grep -c '"confidence" : "possible"' "$SCAN_OUTPUT" || true)
if [[ "$CONFIRMED_COUNT" -ne 2 || "$POSSIBLE_COUNT" -ne 1 ]]; then
  echo "unexpected scan result: confirmed=$CONFIRMED_COUNT possible=$POSSIBLE_COUNT" >&2
  exit 1
fi

PORT=$((20000 + ($$ % 20000)))
SERVER_URL="http://127.0.0.1:$PORT"
SERVER_DATA="$E2E_DIR/server-data"
start_server() {
  AGENTNEST_DEVELOPMENT_LICENSE_KEY="E2E-FULL-LICENSE" \
    "$SERVER_PATH" --listen "127.0.0.1:$PORT" --data "$SERVER_DATA" \
    > "$E2E_DIR/server.stdout" 2> "$E2E_DIR/server.stderr" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    if curl --fail --silent "$SERVER_URL/healthz" >/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "license server failed to start" >&2
  return 1
}

start_server
curl --fail --silent "$SERVER_URL/v1/public-key" > "$E2E_DIR/public-key.json"
PUBLIC_KEY=$(plutil -extract publicKey raw -o - "$E2E_DIR/public-key.json")

TRIAL_ONE="$E2E_DIR/trial-one.json"
"$CLI_PATH" license-trial --server "$SERVER_URL" --machine-id "e2e-device-one" --public-key "$PUBLIC_KEY" > "$TRIAL_ONE"
if [[ $(plutil -extract entitlement.plan raw -o - "$TRIAL_ONE") != "trial" ]]; then
  echo "trial entitlement was not issued" >&2
  exit 1
fi
TRIAL_EXPIRY=$(plutil -extract entitlement.subscriptionExpiresAt raw -o - "$TRIAL_ONE")

kill "$SERVER_PID"
wait "$SERVER_PID" || true
SERVER_PID=""
start_server
curl --fail --silent "$SERVER_URL/v1/public-key" > "$E2E_DIR/public-key-after-restart.json"
PUBLIC_KEY_AFTER_RESTART=$(plutil -extract publicKey raw -o - "$E2E_DIR/public-key-after-restart.json")
if [[ "$PUBLIC_KEY" != "$PUBLIC_KEY_AFTER_RESTART" ]]; then
  echo "signing identity changed after restart" >&2
  exit 1
fi

TRIAL_TWO="$E2E_DIR/trial-two.json"
"$CLI_PATH" license-trial --server "$SERVER_URL" --machine-id "e2e-device-one" --public-key "$PUBLIC_KEY" > "$TRIAL_TWO"
if [[ $(plutil -extract entitlement.subscriptionExpiresAt raw -o - "$TRIAL_TWO") != "$TRIAL_EXPIRY" ]]; then
  echo "trial restarted after service restart" >&2
  exit 1
fi

ACTIVATION="$E2E_DIR/activation.json"
"$CLI_PATH" license-activate --server "$SERVER_URL" --machine-id "e2e-device-one" \
  --public-key "$PUBLIC_KEY" --license-key "E2E-FULL-LICENSE" > "$ACTIVATION"
if [[ $(plutil -extract entitlement.plan raw -o - "$ACTIVATION") != "developer" ]]; then
  echo "paid entitlement was not issued" >&2
  exit 1
fi
plutil -extract receipt json -o "$E2E_DIR/receipt.json" "$ACTIVATION"
"$CLI_PATH" license-verify --receipt "$E2E_DIR/receipt.json" --machine-id "e2e-device-one" --public-key "$PUBLIC_KEY" >/dev/null

if "$CLI_PATH" license-verify --receipt "$E2E_DIR/receipt.json" --machine-id "e2e-device-two" --public-key "$PUBLIC_KEY" >/dev/null 2>&1; then
  echo "cross-device receipt unexpectedly verified" >&2
  exit 1
fi

PAYLOAD=$(plutil -extract payload raw -o - "$E2E_DIR/receipt.json")
plutil -replace payload -string "${PAYLOAD}A" "$E2E_DIR/receipt.json"
if "$CLI_PATH" license-verify --receipt "$E2E_DIR/receipt.json" --machine-id "e2e-device-one" --public-key "$PUBLIC_KEY" >/dev/null 2>&1; then
  echo "tampered receipt unexpectedly verified" >&2
  exit 1
fi

if "$CLI_PATH" license-activate --server "$SERVER_URL" --machine-id "e2e-device-two" \
  --public-key "$PUBLIC_KEY" --license-key "E2E-FULL-LICENSE" >/dev/null 2>&1; then
  echo "device limit was not enforced" >&2
  exit 1
fi

echo "E2E passed: multi-home scan, persistent trial, signed activation, tamper/device binding, device limit"
