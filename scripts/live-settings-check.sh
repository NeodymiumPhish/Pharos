#!/bin/bash
# Live check of the Settings window, driven through the accessibility API.
#
# Usage: scripts/live-settings-check.sh <Pharos.app>
#
# Follows scripts/baseline-navigation-layer.sh: the app runs from a
# re-identified COPY (bundle id com.pharos.client.settingscheck, re-signed ad
# hoc) with its own defaults domain, its own empty Application Support store
# and its own Keychain service, addressed by the pid this script launched and
# killed by that pid alone. A scratch HOME isolates nothing (tasks/lessons.md).
#
# Screen capture is blocked on this host, so every assertion MEASURES: frames
# and values read back through the accessibility server, never a screenshot.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC_APP="${1:?usage: $0 <Pharos.app>}"
[ -x "$SRC_APP/Contents/MacOS/Pharos" ] || { echo "not an app bundle: $SRC_APP" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pharos-settings-check.XXXXXX")"
PID=""
cleanup() {
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

swiftc -O -o "$WORK/ax-walk" scripts/ax-walk.swift
swiftc -O -o "$WORK/ax-do" scripts/ax-do.swift

BUNDLE=com.pharos.client.settingscheck

# Start from a virgin identity. The defaults domain and the Application
# Support store belong to this bundle id alone, and a previous run leaves the
# remembered pane and the flipped switch behind — which turned the "opens in
# General" check into a check of the last run.
defaults delete "$BUNDLE" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/$BUNDLE"
rm -rf "$HOME/Library/Preferences/$BUNDLE.plist"

APP="$WORK/Pharos.app"
cp -R "$SRC_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null
BIN="$APP/Contents/MacOS/Pharos"

failures=0
pass() { echo "PASS $1"; }
fail() { failures=$((failures + 1)); echo "FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected [$3], got [$2]"; fi; }

launch() {
  PHAROS_KEYCHAIN_SERVICE=$BUNDLE "$BIN" >"$WORK/stdout.log" 2>"$WORK/stderr.log" &
  PID=$!
  "$WORK/ax-walk" "$PID" --wait-window 25 --depth 0 >/dev/null
  sleep 2
  # Every keystroke run re-activates the app: pressing a control through the
  # accessibility API does NOT bring it forward (tasks/lessons.md).
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
  "$WORK/ax-do" "$PID" menu "Settings…" >/dev/null
  sleep 1
}

stop() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
}

walk() { "$WORK/ax-walk" "$PID" --depth 12 --pretty; }

launch
walk > "$WORK/walk1.json"

python3 - "$WORK/walk1.json" <<'PY' > "$WORK/report1.txt"
import json, sys
w = json.load(open(sys.argv[1]))

def nodes(n, acc=None):
    acc = [] if acc is None else acc
    acc.append(n)
    for c in n.get("children", []) or []:
        nodes(c, acc)
    return acc

all_nodes = nodes(w["tree"])
titles = [n.get("title", "") for n in all_nodes if n.get("role") == "AXWindow"]
print("WINDOW_TITLES=" + "|".join(t for t in titles if t))

def find(pred):
    return [n for n in all_nodes if pred(n)]

tables = find(lambda n: n.get("identifier") == "settings.sidebar")
print("SIDEBAR_FOUND=%d" % len(tables))
if tables:
    rows = [n for n in nodes(tables[0]) if n.get("role") == "AXRow"]
    print("SIDEBAR_ROWS=%d" % len(rows))
    ids = [n.get("identifier", "") for n in nodes(tables[0]) if (n.get("identifier") or "").startswith("settings.pane.")]
    seen = []
    for i in ids:
        if i not in seen:
            seen.append(i)
    print("PANE_IDS=" + ",".join(seen))
    f = tables[0].get("frame") or {}
    print("SIDEBAR_FRAME=%s,%s,%s,%s" % (f.get("x"), f.get("y"), f.get("w"), f.get("h")))

for ident in ("settings.title", "settings.nav"):
    hits = find(lambda n, i=ident: n.get("identifier") == i)
    if hits:
        f = hits[0].get("frame") or {}
        print("%s_FRAME=%s,%s,%s,%s" % (ident.replace(".", "_").upper(), f.get("x"), f.get("y"), f.get("w"), f.get("h")))
        print("%s_VALUE=%s" % (ident.replace(".", "_").upper(), hits[0].get("value") or hits[0].get("title") or ""))
    else:
        print("%s_FRAME=MISSING" % ident.replace(".", "_").upper())

win = [n for n in all_nodes if n.get("role") == "AXWindow" and "Settings" in (n.get("title") or "")]
if win:
    f = win[0].get("frame") or {}
    print("SETTINGS_WINDOW_FRAME=%s,%s,%s,%s" % (f.get("x"), f.get("y"), f.get("w"), f.get("h")))
PY

cat "$WORK/report1.txt"

# Read the report by lookup, never by sourcing it: the window title contains an
# em dash, which `export` rejects, and sourcing a data file runs whatever the
# app happened to put in it.
val() { grep -E "^$1=" "$WORK/report1.txt" | head -1 | cut -d= -f2-; }
WINDOW_TITLES=$(val WINDOW_TITLES)
SIDEBAR_FOUND=$(val SIDEBAR_FOUND)
SIDEBAR_ROWS=$(val SIDEBAR_ROWS)
PANE_IDS=$(val PANE_IDS)
SETTINGS_TITLE_FRAME=$(val SETTINGS_TITLE_FRAME)
SETTINGS_NAV_FRAME=$(val SETTINGS_NAV_FRAME)

case "$WINDOW_TITLES" in
  *"Pharos Settings — General"*) pass "window title follows the pane (General)" ;;
  *) fail "window title follows the pane — got [$WINDOW_TITLES]" ;;
esac
check "the sidebar table exists" "$SIDEBAR_FOUND" "1"
check "the sidebar has 16 rows" "${SIDEBAR_ROWS:-0}" "16"
case "${PANE_IDS:-}" in
  settings.pane.general,settings.pane.appearance,settings.pane.editor,settings.pane.query,*settings.pane.advanced) pass "sidebar rows are in registry order" ;;
  *) fail "sidebar rows are in registry order — got [${PANE_IDS:-}]" ;;
esac
[ "${SETTINGS_TITLE_FRAME:-MISSING}" != "MISSING" ] && pass "the header title is on screen" || fail "the header title is on screen"
[ "${SETTINGS_NAV_FRAME:-MISSING}" != "MISSING" ] && pass "the back/forward control is on screen" || fail "the back/forward control is on screen"

python3 - "$WORK/report1.txt" <<'PY'
import sys
vals = dict(l.strip().split("=", 1) for l in open(sys.argv[1]) if "=" in l)
def frame(key):
    v = vals.get(key, "")
    try:
        return [float(x) for x in v.split(",")]
    except ValueError:
        return None
side = frame("SIDEBAR_FRAME"); title = frame("SETTINGS_TITLE_FRAME"); win = frame("SETTINGS_WINDOW_FRAME")
nav = frame("SETTINGS_NAV_FRAME")
ok = 0
if side and nav:
    gap = nav[0] - (side[0] + side[2])
    print(("PASS" if 0 <= gap <= 40 else "FAIL") + " the header starts just right of the sidebar (gap %.1f)" % gap)
    ok += 0 if 0 <= gap <= 40 else 1
if nav and title:
    order = title[0] > nav[0] + nav[2] - 1
    print(("PASS" if order else "FAIL") + " the title follows the back/forward control")
    ok += 0 if order else 1
if win and title:
    below = title[1] - win[1]
    print(("PASS" if below >= 20 else "FAIL") + " the header title sits below the title bar (%.1f pt down)" % below)
    ok += 0 if below >= 20 else 1
if win:
    big = win[2] >= 880 and win[3] >= 620
    print(("PASS" if big else "FAIL") + " the window opens at its default size (%.0fx%.0f, want >= 880x620)" % (win[2], win[3]))
    ok += 0 if big else 1
sys.exit(1 if ok else 0)
PY
[ $? -eq 0 ] || failures=$((failures + 1))

# --- Selecting each pane changes both titles ---
for spec in "1:Appearance" "3:Query" "10:Charts" "15:Advanced"; do
  idx="${spec%%:*}"; want="${spec##*:}"
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
  "$WORK/ax-do" "$PID" select-row settings.sidebar "$idx" "Settings" >/dev/null
  sleep 0.6
  got_title=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
ns=nodes(w['tree'])
t=[n for n in ns if n.get('identifier')=='settings.title']
print((t[0].get('value') or t[0].get('title') or '') if t else 'MISSING')
")
  got_window=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
print('|'.join(n.get('title','') for n in nodes(w['tree']) if n.get('role')=='AXWindow' and 'Settings' in (n.get('title') or '')))
")
  check "selecting row $idx shows the $want header" "$got_title" "$want"
  check "selecting row $idx retitles the window" "$got_window" "Pharos Settings — $want"
done

# --- A setting survives navigation and a relaunch ---
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
"$WORK/ax-do" "$PID" select-row settings.sidebar 3 "Settings" >/dev/null
sleep 0.6
before=$("$WORK/ax-do" "$PID" list "Settings" | grep "settings.query.confirmDestructive" | head -1 | sed 's/.*value=//')
# AXButton, not AXCheckBox: an NSSwitch publishes the button role with a 0/1
# value on macOS 26 (measured 2026-09-19). A press toggles it.
"$WORK/ax-do" "$PID" press AXButton settings.query.confirmDestructive "Settings" >/dev/null
sleep 0.6
after=$("$WORK/ax-do" "$PID" list "Settings" | grep "settings.query.confirmDestructive" | head -1 | sed 's/.*value=//')
if [ "$before" != "$after" ]; then pass "the destructive-confirm switch changes value ($before → $after)"; else fail "the destructive-confirm switch changes value (stayed $before)"; fi

"$WORK/ax-do" "$PID" select-row settings.sidebar 0 "Settings" >/dev/null
sleep 0.4
"$WORK/ax-do" "$PID" select-row settings.sidebar 3 "Settings" >/dev/null
sleep 0.6
again=$("$WORK/ax-do" "$PID" list "Settings" | grep "settings.query.confirmDestructive" | head -1 | sed 's/.*value=//')
check "the change survives navigating away and back" "$again" "$after"

stop
launch
relaunched=$("$WORK/ax-do" "$PID" list "Settings" | grep "settings.query.confirmDestructive" | head -1 | sed 's/.*value=//')
last_window=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
print('|'.join(n.get('title','') for n in nodes(w['tree']) if n.get('role')=='AXWindow' and 'Settings' in (n.get('title') or '')))
")
check "the change survives a relaunch of the same identity" "$relaunched" "$after"
check "the window reopens in the remembered pane" "$last_window" "Pharos Settings — Query"
stop

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures FAILURE(S)"; fi
exit $([ "$failures" -eq 0 ] && echo 0 || echo 1)
