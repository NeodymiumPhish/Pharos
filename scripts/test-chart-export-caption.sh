#!/bin/bash
# Standalone test runner for ChartExportCaption — no Xcode project involvement.
# Only the pure caption builder is Foundation-only/testable this way; the
# SwiftUI/ImageRenderer half of chart export (ChartExporter.swift) is
# build-gated and manually verified instead.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-export-caption-tests \
  Pharos/Models/Charts/ChartExportCaption.swift \
  PharosTests/ChartExportCaptionTests.swift \
  PharosTests/main.swift
/tmp/chart-export-caption-tests
