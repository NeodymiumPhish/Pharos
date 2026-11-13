#!/bin/bash
# Standalone test runner for a card's "Describe the query" draft: the
# session, the one-at-a-time queue and the store. Foundation only — the
# worker that asks the model is a closure, faked here.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-card-draft-session-tests
swiftc -o "$bin" \
  Pharos/Core/Cards/CardDraftSession.swift \
  PharosTests/CardDraftSessionTests.swift \
  PharosTests/main.swift
"$bin"
