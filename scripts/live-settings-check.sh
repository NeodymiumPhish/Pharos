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
    # The FIRST ROW, not the table. The table now spans the full window height
    # so its rows can scroll under the toolbar, which makes its own top edge
    # useless as "where content starts" — the first row is the real answer.
    if rows:
        r = rows[0].get("frame") or {}
        print("FIRST_ROW_FRAME=%s,%s,%s,%s" % (r.get("x"), r.get("y"), r.get("w"), r.get("h")))

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
check "the sidebar has 17 rows" "${SIDEBAR_ROWS:-0}" "17"
case "${PANE_IDS:-}" in
  settings.pane.general,settings.pane.appearance,settings.pane.editor,settings.pane.query,*settings.pane.advanced,settings.pane.about) pass "sidebar rows are in registry order, About last" ;;
  *) fail "sidebar rows are in registry order — got [${PANE_IDS:-}]" ;;
esac
[ "${SETTINGS_TITLE_FRAME:-MISSING}" != "MISSING" ] && pass "the pane title is on screen" || fail "the pane title is on screen"
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
nav = frame("SETTINGS_NAV_FRAME"); row0 = frame("FIRST_ROW_FRAME")
ok = 0
if side and nav:
    gap = nav[0] - (side[0] + side[2])
    print(("PASS" if 0 <= gap <= 40 else "FAIL") + " the back/forward starts just right of the sidebar (gap %.1f)" % gap)
    ok += 0 if 0 <= gap <= 40 else 1
if nav and title:
    order = title[0] > nav[0] + nav[2] - 1
    print(("PASS" if order else "FAIL") + " the title follows the back/forward control")
    ok += 0 if order else 1
# The whole point of the 2026-09-20 chrome change: this furniture is in the
# TITLE BAR now, not in a row inside the detail pane. Measured against the
# FIRST SIDEBAR ROW rather than a magic title-bar height: the row is the first
# thing the user reads, so furniture above it is in the bar. The old assertion
# here was the opposite (title >= 20 pt BELOW the window top) and had to
# invert, not relax.
for label, f in (("the pane title", title), ("the back/forward", nav)):
    if f and row0 and win:
        centre = f[1] + f[3] / 2
        inbar = win[1] <= centre < row0[1]
        print(("PASS" if inbar else "FAIL")
              + " %s sits in the title bar (centre %.1f, first row at %.1f)" % (label, centre, row0[1]))
        ok += 0 if inbar else 1

# No dead band between the toolbar and the first row.
#
# The scroll-under itself is NOT assertable here: the sidebar's scroll view
# insets its own content by the titlebar, so the clip runs full height while
# the TABLE — which is what accessibility reports a frame for — still starts
# below the inset. What is observable, and is what the reader actually sees,
# is that no empty strip is left between the chevrons and the first row.
if nav and row0:
    band = row0[1] - (nav[1] + nav[3])
    print(("PASS" if 0 <= band <= 12 else "FAIL")
          + " the first sidebar row sits right under the toolbar (%.1f pt gap)" % band)
    ok += 0 if 0 <= band <= 12 else 1
if win:
    big = win[2] >= 880 and win[3] >= 620
    print(("PASS" if big else "FAIL") + " the window opens at its default size (%.0fx%.0f, want >= 880x620)" % (win[2], win[3]))
    ok += 0 if big else 1
sys.exit(1 if ok else 0)
PY
[ $? -eq 0 ] || failures=$((failures + 1))

# --- Selecting each pane changes both titles ---
for spec in "1:Appearance" "3:Query" "8:Security & Privacy" "10:Charts" "15:Advanced"; do
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
  got_width=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
t=[n for n in nodes(w['tree']) if n.get('identifier')=='settings.title']
print(int((t[0].get('frame') or {}).get('w') or 0) if t else 0)
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
  check "selecting row $idx shows the $want title" "$got_title" "$want"
  # The item must re-measure: a title wider than "General" (59 pt) proves it,
  # and a title stuck at 59 pt for a long name proves the opposite.
  want_len=${#want}
  if [ "$want_len" -ge 10 ]; then
    if [ "${got_width:-0}" -gt 62 ]; then
      pass "the toolbar title grew to fit [$want] (${got_width}pt)"
    else
      fail "the toolbar title grew to fit [$want] — stuck at ${got_width}pt"
    fi
  fi
  check "selecting row $idx retitles the window" "$got_window" "Pharos Settings — $want"
done

# --- The toolbar search filters the sidebar ---
#
# Typed, not set. `AXUIElementSetAttributeValue(kAXValueAttribute)` writes a
# field's string WITHOUT going through the field editor, so no
# controlTextDidChange, no action, no filtering — tasks/lessons.md records
# exactly this trap for a toolbar filter field. System Events keystrokes go
# through the real input path.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
if "$WORK/ax-do" "$PID" focus AXTextField settings.search "Settings" >/dev/null 2>&1; then
  osascript -e 'tell application "System Events" to keystroke "boolean"' >/dev/null
  sleep 0.8
  FILTERED=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
ns=nodes(w['tree'])
t=[n for n in ns if n.get('identifier')=='settings.sidebar']
if not t:
    print('MISSING')
else:
    rows=[n for n in nodes(t[0]) if n.get('role')=='AXRow']
    ids=[]
    for n in nodes(t[0]):
        i=n.get('identifier') or ''
        if i.startswith('settings.pane.') and i not in ids: ids.append(i)
    print('%d|%s' % (len(rows), ','.join(ids)))
")
  # Asserted as "narrowed, best match first" rather than as an exact list.
  # "boolean" legitimately hits Appearance's `Boolean display` ROW and the
  # Editor pane's caption about quoting lists of booleans — and a caption is a
  # real match. What must hold is that the title match ranks above the caption
  # one, and that the list shrank.
  FILTERED_COUNT=${FILTERED%%|*}
  FILTERED_FIRST=$(echo "${FILTERED#*|}" | cut -d, -f1)
  if [ "${FILTERED_COUNT:-17}" -lt 17 ] && [ "${FILTERED_COUNT:-0}" -ge 1 ]; then
    pass "a query narrows the sidebar ($FILTERED_COUNT of 17)"
  else
    fail "a query narrows the sidebar — got [$FILTERED]"
  fi
  check "the pane whose ROW title matches is listed first" "$FILTERED_FIRST" "settings.pane.appearance"

  # Clearing it puts all 16 back.
  osascript -e 'tell application "System Events" to key code 53' >/dev/null   # esc
  sleep 0.8
  RESTORED=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
t=[n for n in nodes(w['tree']) if n.get('identifier')=='settings.sidebar']
print(len([n for n in nodes(t[0]) if n.get('role')=='AXRow']) if t else 0)
")
  check "clearing the search restores every pane" "$RESTORED" "17"
else
  fail "the search field is in the toolbar and can take focus"
fi

# --- The Appearance tiles are a real radio group ---
#
# A hand-drawn NSControl publishes nothing to accessibility unless it is asked
# to. Three tiles that a screen reader cannot see, or cannot tell apart, would
# look perfect and be unusable.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
"$WORK/ax-do" "$PID" select-row settings.sidebar 1 "Settings" >/dev/null
sleep 0.6
TILES=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
t=[n for n in nodes(w['tree']) if n.get('identifier')=='settings.appearance.appearance']
if not t:
    print('MISSING')
else:
    kids=[c for c in (t[0].get('children') or []) if c.get('role')=='AXRadioButton']
    print('%s|%d|%s' % (t[0].get('role'), len(kids), ','.join(c.get('title') or c.get('description') or '?' for c in kids)))
")
check "the appearance chooser is a radio group of three tiles" "$(echo "$TILES" | cut -d'|' -f1-2)" "AXRadioGroup|3"
case "$TILES" in
  *System,Light,Dark*) pass "the tiles are named System, Light and Dark" ;;
  *) fail "the tiles are named System, Light and Dark — got [$TILES]" ;;
esac

# --- Settings ▸ About: the hero, the links, and the deep link from the menu ---
#
# About replaced the system About panel, which means three things have to be
# true in a running app and none of them is testable in a harness: the pane is
# reachable from the menu bar, the hero it opens with is on screen, and the
# deep link does NOT become the pane ⌘, opens next time.
about_report() {
  walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
ns=nodes(w['tree'])
def one(ident):
    hits=[n for n in ns if n.get('identifier')==ident]
    if not hits: return 'MISSING'
    n=hits[0]; f=n.get('frame') or {}
    text=(n.get('value') or n.get('title') or '')
    return '%s@%s,%s,%s,%s' % (text, f.get('x'), f.get('y'), f.get('w'), f.get('h'))
for ident in ('settings.about.name','settings.about.version',
              'settings.about.repository','settings.about.help','settings.about.releaseNotes'):
    print('%s=%s' % (ident, one(ident)))
t=[n for n in ns if n.get('identifier')=='settings.title']
print('TITLE=%s' % ((t[0].get('value') or t[0].get('title') or '') if t else 'MISSING'))
print('WINDOW=%s' % '|'.join(n.get('title','') for n in ns if n.get('role')=='AXWindow' and 'Settings' in (n.get('title') or '')))
"
}

osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
"$WORK/ax-do" "$PID" select-row settings.sidebar 16 "Settings" >/dev/null
sleep 0.8
about_report > "$WORK/about1.txt"
cat "$WORK/about1.txt"
aval() { grep -E "^$1=" "$WORK/about1.txt" | head -1 | cut -d= -f2-; }

check "selecting the last row shows the About title" "$(aval TITLE)" "About"
[ "$(aval settings.about.name)" != "MISSING" ] && pass "the app name is on screen" || fail "the app name is on screen"
case "$(aval settings.about.name)" in
  Pharos@*) pass "the hero names the app" ;;
  *) fail "the hero names the app — got [$(aval settings.about.name)]" ;;
esac
case "$(aval settings.about.version)" in
  "Version "*) pass "the hero reports a version ($(aval settings.about.version | cut -d@ -f1))" ;;
  *) fail "the hero reports a version — got [$(aval settings.about.version)]" ;;
esac
for ident in settings.about.repository settings.about.help settings.about.releaseNotes; do
  if [ "$(aval $ident)" != "MISSING" ]; then pass "$ident is on screen"; else fail "$ident is on screen"; fi
done
# The hero is ABOVE the first row, which is what `headerViews` promises.
python3 - "$WORK/about1.txt" <<'PY3'
import sys
vals = dict(l.strip().split("=", 1) for l in open(sys.argv[1]) if "=" in l)
def frame(key):
    v = vals.get(key, "MISSING")
    if "@" not in v: return None
    try: return [float(x) for x in v.split("@", 1)[1].split(",")]
    except ValueError: return None
name = frame("settings.about.name"); version = frame("settings.about.version")
repo = frame("settings.about.repository")
bad = 0
if name and version:
    print(("PASS" if version[1] > name[1] else "FAIL")
          + " the version line sits under the name (%.1f under %.1f)" % (version[1], name[1]))
    bad += 0 if version[1] > name[1] else 1
if version and repo:
    print(("PASS" if repo[1] > version[1] else "FAIL")
          + " the hero sits above the first row (%.1f above %.1f)" % (version[1], repo[1]))
    bad += 0 if repo[1] > version[1] else 1
sys.exit(1 if bad else 0)
PY3
[ $? -eq 0 ] || failures=$((failures + 1))

# Leave the window on a pane the user would be WORKING in, so the deep link
# below has something to fail to overwrite.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
"$WORK/ax-do" "$PID" select-row settings.sidebar 3 "Settings" >/dev/null
sleep 0.6
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
"$WORK/ax-do" "$PID" menu "About Pharos" >/dev/null
sleep 1
about_report > "$WORK/about2.txt"
aval2() { grep -E "^$1=" "$WORK/about2.txt" | head -1 | cut -d= -f2-; }
check "Pharos ▸ About Pharos opens the About pane" "$(aval2 TITLE)" "About"
check "…and retitles the window" "$(aval2 WINDOW)" "Pharos Settings — About"

# The rule the deep link exists for: About is read once, so ⌘, must still
# open the pane the user was working in.
REMEMBERED=$(defaults read "$BUNDLE" PharosSettingsPane 2>/dev/null || echo MISSING)
check "the deep link does not become the remembered pane" "$REMEMBERED" "query"
stop
launch
after_about=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
print('|'.join(n.get('title','') for n in nodes(w['tree']) if n.get('role')=='AXWindow' and 'Settings' in (n.get('title') or '')))
")
check "after About, the window still reopens in the working pane" "$after_about" "Pharos Settings — Query"

# --- The Shortcuts pane clears the toolbar ---
#
# Every other pane is a scroll view that insets itself by the titlebar. This
# one is a search field above a table, laid out by hand, so it is the single
# pane that has to ask for the safe area itself — and the only one where
# getting it wrong hides a control behind the toolbar rather than merely
# shifting it.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
"$WORK/ax-do" "$PID" select-row settings.sidebar 14 "Settings" >/dev/null
sleep 0.6
SHORTCUT_SEARCH_Y=$(walk | python3 -c "
import json,sys
w=json.load(sys.stdin)
def nodes(n,acc=None):
    acc=[] if acc is None else acc
    acc.append(n)
    for c in n.get('children',[]) or []: nodes(c,acc)
    return acc
t=[n for n in nodes(w['tree']) if n.get('identifier')=='settings.shortcuts.search']
print((t[0].get('frame') or {}).get('y') if t else 'MISSING')
")
if [ "${SHORTCUT_SEARCH_Y:-MISSING}" = "MISSING" ]; then
  fail "the Shortcuts search field is on screen"
else
  python3 - "$SHORTCUT_SEARCH_Y" "$(val FIRST_ROW_FRAME | cut -d, -f2)" <<'PY2'
import sys
y = float(sys.argv[1]); content = float(sys.argv[2])
# At or below where the sidebar's first row starts: both are the first thing
# under the toolbar on their side of the window.
print(("PASS" if y >= content - 4 else "FAIL")
      + " the Shortcuts search field clears the toolbar (y %.1f, content starts %.1f)" % (y, content))
sys.exit(0 if y >= content - 4 else 1)
PY2
  [ $? -eq 0 ] || failures=$((failures + 1))
fi

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
