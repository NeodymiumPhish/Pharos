#!/bin/bash
# Standalone runner for TagGlob. Foundation only — the engine depends on
# nothing else, which is the point of keeping it in its own file.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-glob-tests \
  Pharos/Core/TagGlob.swift \
  PharosTests/TagGlobTests.swift \
  PharosTests/main.swift
/tmp/tag-glob-tests
