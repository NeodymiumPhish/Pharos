#!/bin/bash
# Standalone test runner for the pure half of "Describe the query":
# SchemaSnapshot (the tool OUTPUT formatters), SQLDraftPolicy and the
# DestructiveSQLScanner it reviews with. Foundation only — the
# FoundationModels session and the two `Tool` conformances live in
# Pharos/Intelligence/SQLDraft.swift and are deliberately NOT compiled here.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-draft-policy-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Utilities/DestructiveSQLScanner.swift \
  Pharos/Intelligence/SQLDraftSchema.swift \
  Pharos/Intelligence/SQLDraftPolicy.swift \
  PharosTests/SQLDraftPolicyTests.swift \
  PharosTests/main.swift
/tmp/sql-draft-policy-tests
