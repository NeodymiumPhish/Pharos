#!/bin/bash
# Standalone runner for TagManagerModel. Foundation only — the model holds no
# AppKit and reaches no store, which is what lets this suite pin every decision
# the Tag Manager makes before any of its UI exists.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-manager-model-tests \
  Pharos/Core/TagManagerModel.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Models/Tag.swift \
  PharosTests/TagManagerModelTests.swift \
  PharosTests/main.swift
/tmp/tag-manager-model-tests
