#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Settings.swift (and ChartPalette behind it) come along for `ResultDateStyle`
# and `ResultNumberStyle`, which `ResultCellText.rendered` now takes; the
# formatter itself is tested on its own in test-result-value-formatter.sh.
swiftc -o /tmp/result-cell-text-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Core/ResultValueFormatter.swift \
  Pharos/ViewControllers/ResultsGrid/ResultCellText.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/ResultCellTextTests.swift \
  PharosTests/main.swift
/tmp/result-cell-text-tests
