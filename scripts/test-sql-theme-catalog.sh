#!/bin/bash
# Standalone test runner for SQLTheme's named catalogue — that every offered
# name resolves, that the names are unique, and that "system" is today's
# colours exactly. No Xcode project involvement.
#
# Settings.swift comes along only for EditorSettings().syntaxTheme, which the
# suite pins against SQLTheme.systemThemeName.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-sql-theme-catalog-tests \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Editor/SQLThemeCatalog.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/SQLThemeCatalogTests.swift \
  PharosTests/main.swift
/tmp/pharos-sql-theme-catalog-tests
