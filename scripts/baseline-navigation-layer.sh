#!/bin/bash
# Capture the live navigation-layer baseline: window bounds and the frames of the
# split group, its three panes, the toolbar, and every sidebar control, read back
# through the accessibility server from a real launch.
#
# Usage: scripts/baseline-navigation-layer.sh <Pharos.app> [output.json]
#
# The app runs from a re-identified COPY (bundle id com.pharos.client.scratch,
# re-signed ad hoc) with a scratch HOME. HOME alone gives an empty store (no
# connections, no Keychain lookups) but NOT fresh defaults: cfprefsd keys the
# preference domain by uid and bundle id and ignores HOME and CFFIXED_USER_HOME,
# so the split view and window autosave would come from, and write back to, the
# real com.pharos.client domain. The bundle id change gives the copy its own
# domain (tasks/lessons.md, 2026-09-14).
# The window is confirmed through the window server before the walk
# (tasks/lessons.md: a launch is verified only when an on-screen window exists).
# The process is killed by the pid this script started, never by name.
#
# Output JSON: {app, captured_at, windows:[...], tree:{...}} from scripts/ax-walk.swift,
# filtered to the roles that describe layout. Diff two captures with:
#   jq -S 'del(.captured_at, .pid)' a.json > a.norm; jq -S 'del(.captured_at, .pid)' b.json > b.norm; diff a.norm b.norm
set -euo pipefail
cd "$(dirname "$0")/.."

SRC_APP="${1:?usage: $0 <Pharos.app> [output.json]}"
OUT="${2:-scripts/baselines/navigation-layer.json}"
[ -x "$SRC_APP/Contents/MacOS/Pharos" ] || { echo "not an app bundle: $SRC_APP" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pharos-baseline.XXXXXX")"
trap 'if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID"; fi; rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/ax-walk" scripts/ax-walk.swift

APP="$WORK/Pharos.app"
cp -R "$SRC_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.pharos.client.scratch" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null
BIN="$APP/Contents/MacOS/Pharos"

mkdir -p "$WORK/home"
HOME="$WORK/home" "$BIN" >"$WORK/stdout.log" 2>"$WORK/stderr.log" &
PID=$!
echo "launched pid $PID with scratch HOME $WORK/home" >&2

# Wait for an on-screen window, then let the first layout settle.
"$WORK/ax-walk" "$PID" --wait-window 20 --depth 0 >/dev/null
sleep 2

"$WORK/ax-walk" "$PID" --depth 9 --pretty \
  --roles AXWindow,AXToolbar,AXButton,AXSplitGroup,AXSplitter,AXGroup,AXScrollArea,AXOutline,AXTable,AXTextField,AXTextArea,AXRadioGroup,AXRadioButton,AXPopUpButton,AXMenuButton,AXStaticText,AXTabGroup \
  >"$WORK/walk.json"

mkdir -p "$(dirname "$OUT")"
python3 - "$WORK/walk.json" "$OUT" "$APP" <<'PY'
import json, sys, datetime
walk = json.load(open(sys.argv[1]))
walk.pop("pid", None)
walk["app"] = sys.argv[3]  # the source bundle; the capture ran a re-identified copy
walk["captured_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
json.dump(walk, open(sys.argv[2], "w"), indent=2, sort_keys=True)
print(sys.argv[2])
PY

kill "$PID"
wait "$PID" 2>/dev/null || true
PID=""
[ -s "$WORK/stderr.log" ] && { echo "--- app stderr ---" >&2; tail -20 "$WORK/stderr.log" >&2; }
exit 0
