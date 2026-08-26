// Shared entry point for every standalone test binary in this repo.
//
// This project has no Xcode test target. Instead each `scripts/test-*.sh` invokes
// `swiftc` with the implementation files under test, exactly one test file from
// `PharosTests/` that declares `runTests()`, and this shim as the binary's `main`.
// One test file per binary is therefore the rule — two would collide on
// `runTests()` and on the assertion helpers each file defines for itself.
import Foundation

// Line-buffer stdout before anything prints.
//
// Swift BLOCK-buffers stdout when it is not a tty, so a suite that traps loses
// every line it had printed — and `bash suite.sh > /dev/null 2>&1` is exactly
// how the sweep runs. A trapped suite then presents as a non-zero exit with no
// FAIL lines, which is indistinguishable from a mutation that never applied.
// That cost a real investigation once; see tasks/lessons.md.
//
// `_IOLBF`, not `_IONBF`: every assertion prints a whole line, so line
// buffering gives identical crash-safety for a fraction of the syscalls.
setvbuf(stdout, nil, _IOLBF, 0)

runTests()
