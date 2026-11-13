#!/bin/bash
# Standalone test runner for a card's "Describe the query" strip, its place
# in the card and the name row's Describe button. Real AppKit, headless.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-draft-view-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/Cards/CardPresentation.swift \
  Pharos/ViewControllers/Cards/CardViews.swift \
  Pharos/Editor/FindHighlights.swift \
  Pharos/ViewControllers/Cards/CardNotesView.swift \
  Pharos/ViewControllers/Cards/CardDraftView.swift \
  Pharos/Core/Cards/CardDraftSession.swift \
  Pharos/ViewControllers/Cards/CardResultsHeaderView.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
  Pharos/Models/QueryVariable.swift \
  PharosTests/CardDraftViewTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-draft-view-tests
