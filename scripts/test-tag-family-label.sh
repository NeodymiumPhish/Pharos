#!/bin/bash
# Standalone runner for TagFamilyLabel. Pulls in TagValueNormalizer for the
# family constants, CIDRRange because the normalizer's address branch needs it,
# and DisplayEscape for the escaping on the way out.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-family-label-tests \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/TagFamilyLabelTests.swift \
  PharosTests/main.swift
/tmp/tag-family-label-tests
