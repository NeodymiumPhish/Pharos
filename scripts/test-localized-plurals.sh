#!/bin/bash
# Standalone test runner for CountedNounText. Pure Foundation, no AppKit —
# and no app bundle or String Catalog either, which is the point: it proves
# `AttributedString(localized: "^[...](inflect: true)")` resolves automatic
# grammatical agreement even from a bare swiftc binary, and it is what caught
# "tuple" not being in the inflector's built-in English dictionary.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/localized-plurals-tests \
  Pharos/Core/CountedNounText.swift \
  PharosTests/CountedNounTextTests.swift \
  PharosTests/main.swift
/tmp/localized-plurals-tests
