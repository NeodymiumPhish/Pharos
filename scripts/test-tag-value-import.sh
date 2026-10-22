#!/bin/bash
# Standalone test runner for TagValueImport: Add Values… — one rule per line,
# the type detected from the value, repeats and existing rules left out, and
# values the matcher refuses shown, never added.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-value-import-tests \
  Pharos/Core/TagValueImport.swift \
  Pharos/Core/TagConditionEditor.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Models/Tag.swift \
  PharosTests/TagValueImportTests.swift \
  PharosTests/main.swift
/tmp/tag-value-import-tests
