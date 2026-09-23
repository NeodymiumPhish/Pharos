#!/bin/bash
# Standalone test runner for SQLStatementScope — what the statement around
# the caret names and what the caret expects next. Foundation only; the lexer,
# its snapshot and the segment parser come along because the scope reads them.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-sql-statement-scope-tests \
  Pharos/Editor/SQLStatementScope.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  PharosTests/SQLStatementScopeTests.swift \
  PharosTests/main.swift
/tmp/pharos-sql-statement-scope-tests
