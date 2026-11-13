#!/bin/bash
# Standalone test runner for the model half of the "Describe a query"
# pipeline: SQLDraftPipeline in Pharos/Intelligence/SQLDraft.swift, asked
# through a stand-in IntelligenceBackend. It checks what the pipeline sends
# and what it does with each answer; no model runs. The real model is graded
# by scripts/eval-sql-draft.sh, whose stubs this shares.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-sql-draft-backend-tests
swiftc -o "$bin" \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLStatementScope.swift \
  Pharos/Utilities/DestructiveSQLScanner.swift \
  Pharos/Models/SchemaDraftFacts.swift \
  Pharos/Intelligence/SQLDraftSchema.swift \
  Pharos/Intelligence/SQLDraftRanker.swift \
  Pharos/Intelligence/SQLDraftPrompt.swift \
  Pharos/Intelligence/SQLDraftChecker.swift \
  Pharos/Intelligence/SQLDraftFixer.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Intelligence/GeneratedTextPolicy.swift \
  Pharos/Intelligence/SQLDraftPolicy.swift \
  Pharos/Intelligence/ModelErrorKind.swift \
  Pharos/Intelligence/IntelligenceBackend.swift \
  Pharos/Intelligence/IntelligenceEndpoint.swift \
  Pharos/Intelligence/EndpointIntelligenceBackend.swift \
  Pharos/Intelligence/SQLDraft.swift \
  scripts/draft-eval/PipelineStubs.swift \
  PharosTests/SQLDraftBackendTests.swift \
  PharosTests/main.swift
"$bin"
