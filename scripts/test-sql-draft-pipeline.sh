#!/bin/bash
# Standalone test runner for the pure half of the "Describe a query"
# pipeline: DraftCatalog, SQLDraftRanker, SQLDraftPrompt, SQLDraftChecker.
# Foundation only — the FoundationModels sessions in
# Pharos/Intelligence/SQLDraft.swift are not compiled here; the real model is
# graded by scripts/eval-sql-draft.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-sql-draft-pipeline-tests
swiftc -o "$bin" \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLStatementScope.swift \
  Pharos/Models/SchemaDraftFacts.swift \
  Pharos/Intelligence/SQLDraftSchema.swift \
  Pharos/Intelligence/SQLDraftRanker.swift \
  Pharos/Intelligence/SQLDraftPrompt.swift \
  Pharos/Intelligence/SQLDraftChecker.swift \
  Pharos/Intelligence/SQLDraftFixer.swift \
  PharosTests/SQLDraftPipelineTests.swift \
  PharosTests/main.swift
"$bin"
