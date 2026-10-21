#!/bin/bash
# Every menu-bar action that targets ContentViewController needs a forwarder in
# PharosSplitViewController: the window's responder chain reaches the split view
# controller, not the content controller, whenever the focus is outside the
# content pane (or nothing is focused). Without one AppKit finds no target and
# shows the item DISABLED (found 2026-10-21: Query ▸ Attach PostgreSQL
# Connection… was greyed out on a connected DuckDB tab).
set -euo pipefail
cd "$(dirname "$0")/.."

# Present before this check existed; each needs a decision (forward, or make
# it reachable another way). Remove a name when it is fixed.
KNOWN="menuCancelAllQueries menuManageTags menuTagRow showFilter"

failures=0
for action in $(grep -o '#selector(ContentViewController\.[A-Za-z]*' Pharos/App/MainMenu.swift | sed 's/.*\.//' | sort -u); do
    if grep -q "func $action(" Pharos/ViewControllers/PharosSplitViewController.swift; then
        echo "PASS $action is forwarded"
    elif [[ " $KNOWN " == *" $action "* ]]; then
        echo "KNOWN $action has no forwarder (listed)"
    else
        echo "FAIL $action has no forwarder in PharosSplitViewController"
        failures=$((failures + 1))
    fi
done
for known in $KNOWN; do
    if grep -q "func $known(" Pharos/ViewControllers/PharosSplitViewController.swift; then
        echo "FAIL $known is forwarded now: remove it from KNOWN"
        failures=$((failures + 1))
    fi
done
[ "$failures" -eq 0 ] && echo "ALL PASS" || { echo "$failures FAILURE(S)"; exit 1; }
