#!/bin/bash
# Standalone test runner for the workspace-history filter marks — no Xcode
# project involvement. Compiles only the two files that carry the logic
# (HistoryRowText, WorkspacePreviewRowCell) plus the model they read;
# QueryHistoryVC itself is excluded because it pulls in the PharosCore FFI
# bridge, which cannot link in a plain swiftc binary.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/workspace-history-match-tests \
  Pharos/Core/HistoryRowText.swift \
  Pharos/Views/WorkspacePreviewRowCell.swift \
  Pharos/Models/Workspace.swift \
  PharosTests/WorkspaceHistoryMatchTests.swift \
  "$TMPMAIN"
/tmp/workspace-history-match-tests
