#!/bin/bash
# Standalone test runner for CardPresentation — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-presentation-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/Cards/CardPresentation.swift \
  PharosTests/CardPresentationTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-presentation-tests
