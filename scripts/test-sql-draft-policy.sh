#!/bin/bash
# Standalone test runner for SQLDraftPolicy, which cleans and reviews a
# "Describe the query" draft, and the DestructiveSQLScanner it reviews with.
# Foundation only. The pipeline's pure half has its own runner,
# scripts/test-sql-draft-pipeline.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-draft-policy-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Utilities/DestructiveSQLScanner.swift \
  Pharos/Intelligence/SQLDraftPolicy.swift \
  PharosTests/SQLDraftPolicyTests.swift \
  PharosTests/main.swift
/tmp/sql-draft-policy-tests
