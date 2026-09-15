#!/bin/bash
# Standalone test runner for SQLTextView.insertDraft — the edit that puts a
# model draft in the editor. Real AppKit, headless; no window is shown.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-draft-insert-tests \
  Pharos/Editor/SQLTextView.swift \
  Pharos/Editor/SQLCompletionProvider.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Editor/SQLListFormatter.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/Schema.swift \
  PharosTests/SQLDraftInsertTests.swift \
  PharosTests/main.swift
/tmp/sql-draft-insert-tests
