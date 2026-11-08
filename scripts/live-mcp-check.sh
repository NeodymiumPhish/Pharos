#!/bin/bash
# Live check of the MCP server: a running Pharos driven through `Pharos --mcp`
# the way Claude desktop or LM Studio drives it (scripts/mcp-live-driver.py).
#
# Usage: scripts/live-mcp-check.sh <Pharos.app>
#
# Follows scripts/live-settings-check.sh: the app runs from a re-identified
# COPY (bundle id com.pharos.client.mcpcheck, re-signed ad hoc) with its own
# defaults domain, its own Application Support store (so its own MCP socket)
# and its own Keychain service, addressed by the pid this script launched and
# killed by that pid alone. Your own Pharos and its data are not touched.
#
# Before the measured launch the store is seeded, with the app stopped: the
# MCP server and MCP writes on, Settings ▸ Query's own destructive
# confirmation OFF (an MCP run must ask anyway), variable values NOT shared,
# a DuckDB connection `mcp-duck` to a scratch file holding a three-row
# `people` table, and a global number variable `person_id` = 2.
#
# The last check leaves a confirmation sheet on screen; the script then
# kills the copy, so the DELETE never runs.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC_APP="${1:?usage: $0 <Pharos.app>}"
[ -x "$SRC_APP/Contents/MacOS/Pharos" ] || { echo "not an app bundle: $SRC_APP" >&2; exit 2; }
command -v duckdb >/dev/null || { echo "needs the duckdb CLI (brew install duckdb)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pharos-mcp-check.XXXXXX")"
PID=""
BUNDLE=com.pharos.client.mcpcheck
STORE="$HOME/Library/Application Support/$BUNDLE"
cleanup() {
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

defaults delete "$BUNDLE" 2>/dev/null || true
rm -rf "$STORE" "$HOME/Library/Preferences/$BUNDLE.plist"

APP="$WORK/Pharos.app"
cp -R "$SRC_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null
BIN="$APP/Contents/MacOS/Pharos"

launch() {
  PHAROS_KEYCHAIN_SERVICE=$BUNDLE "$BIN" >"$WORK/stdout.log" 2>"$WORK/stderr.log" &
  PID=$!
}
stop() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
}

# 1. A first launch makes the store.
launch
for _ in $(seq 1 100); do [ -f "$STORE/pharos.db" ] && break; sleep 0.2; done
sleep 3
stop
[ -f "$STORE/pharos.db" ] || { echo "FAIL the app made no store" >&2; exit 1; }

# 2. Seed it.
duckdb "$WORK/check.duckdb" "CREATE TABLE people (id INTEGER, name TEXT); INSERT INTO people VALUES (1, 'Ada'), (2, 'Grace'), (3, 'Edsger');"
CURRENT="$(sqlite3 "$STORE/pharos.db" "SELECT settings_json FROM app_settings WHERE id = 1" || true)"
[ -n "$CURRENT" ] || CURRENT="$(cat PharosTests/Fixtures/settings-default.json)"
SETTINGS="$(printf '%s' "$CURRENT" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
s["security"]["mcpServerEnabled"] = True
s["security"]["mcpAllowWrites"] = True
s["query"]["confirmDestructive"] = False
print(json.dumps(s))')"
sqlite3 "$STORE/pharos.db" <<SQL
INSERT INTO app_settings (id, settings_json, updated_at) VALUES (1, '$(printf '%s' "$SETTINGS" | sed "s/'/''/g")', CURRENT_TIMESTAMP)
  ON CONFLICT(id) DO UPDATE SET settings_json = excluded.settings_json;
INSERT INTO connections (id, name, host, port, database, username, engine, saved)
  VALUES ('mcp-duck', 'MCP Check', '', 0, '$WORK/check.duckdb', '', 'duckdb', 1);
INSERT INTO query_variables (id, name, value, type, position)
  VALUES ('$(uuidgen)', 'person_id', '2', 'number', 0);
SQL

# 3. The measured launch: wait for the socket.
launch
SOCKET="$STORE/MCP/pharos.sock"
for _ in $(seq 1 150); do [ -S "$SOCKET" ] && break; sleep 0.2; done
[ -S "$SOCKET" ] || { echo "FAIL the MCP socket did not appear at $SOCKET" >&2; tail -20 "$WORK/stderr.log" >&2; exit 1; }
echo "PASS the server listens at $SOCKET"
[ "$(stat -f %Lp "$SOCKET")" = "600" ] && echo "PASS the socket is 0600" || { echo "FAIL the socket is not 0600"; exit 1; }
sleep 2

STATUS=0
python3 -I scripts/mcp-live-driver.py "$BIN" || STATUS=$?
stop
rows="$(duckdb -noheader -list "$WORK/check.duckdb" "SELECT count(*) FROM people")"
[ "$rows" = "3" ] && echo "PASS the unconfirmed DELETE never ran" || { echo "FAIL people has $rows rows"; STATUS=1; }
rm -rf "$STORE" "$HOME/Library/Preferences/$BUNDLE.plist"
exit $STATUS
