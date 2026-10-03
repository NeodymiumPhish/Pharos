#!/bin/bash
# Standalone test runner for the query card views — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-views-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/Cards/CardPresentation.swift \
  Pharos/ViewControllers/Cards/CardViews.swift \
  Pharos/ViewControllers/Cards/CardResultsHeaderView.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Models/QueryVariable.swift \
  PharosTests/CardViewsTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-views-tests
