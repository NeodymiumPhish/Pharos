// Standalone test runner for FailurePresentationRule — what a failed query
// does on screen. Compiled by scripts/test-failure-presentation-rule.sh.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func decide(_ style: FailureAlertStyle, _ trigger: ErrorSheetTrigger,
                    _ kind: FailurePresentationRule.FailureKind, unread: Int,
                    cancelDialog: Bool = true) -> FailurePresentationRule.Presentation {
    FailurePresentationRule.decide(style: style, trigger: trigger, kind: kind,
                                   unreadBefore: unread, showCancelledDialog: cancelDialog)
}

/// The behaviour the app has today must come out of the defaults unchanged,
/// or the setting has quietly changed what everyone sees.
private func testDefaultsReproduceTodaysBehaviour() {
    expectEqual(decide(.sheet, .secondFailure, .error, unread: 0), .banner,
                "the first unread error gets the banner")
    expectEqual(decide(.sheet, .secondFailure, .error, unread: 1), .sheet,
                "a second unread error opens the sheet")
    expectEqual(decide(.sheet, .secondFailure, .error, unread: 5), .sheet,
                "and any further one keeps opening it")
    // The case this suite originally got WRONG. I read the old presenter as
    // "a first cancellation says nothing"; it opened the sheet, and
    // scripts/test-query-error-presenter.sh had been asserting exactly that
    // since it was written. "The second failure" is a rule about an error,
    // which has a banner to show first; a cancellation has none, so it opens
    // the sheet at once.
    expectEqual(decide(.sheet, .secondFailure, .cancelled, unread: 0), .sheet,
                "a first cancellation opens the sheet, as it always has")
    expectEqual(decide(.sheet, .secondFailure, .cancelled, unread: 0, cancelDialog: false), .nothing,
                "unless the user asked not to be told")
    expectEqual(decide(.sheet, .secondFailure, .cancelled, unread: 1), .sheet,
                "a cancellation after an unread failure opens the sheet")
    expectEqual(decide(.sheet, .secondFailure, .cancelled, unread: 0, cancelDialog: false), .nothing,
                "the cancel-dialog setting silences a cancellation")
    expectEqual(decide(.sheet, .secondFailure, .cancelled, unread: 3, cancelDialog: false), .nothing,
                "…however many failures are unread")
}

private func testTrigger() {
    expectEqual(decide(.sheet, .firstFailure, .error, unread: 0), .sheet,
                "first-failure opens the sheet straight away")
    expectEqual(decide(.sheet, .never, .error, unread: 0), .banner,
                "never still shows the banner for an error")
    expectEqual(decide(.sheet, .never, .error, unread: 9), .banner,
                "never means never, however many are unread")
    expectEqual(decide(.sheet, .never, .cancelled, unread: 9), .nothing,
                "never and a cancellation says nothing")
    expectEqual(decide(.sheet, .firstFailure, .cancelled, unread: 0), .sheet,
                "first-failure and a cancellation opens the sheet too")
}

private func testStyles() {
    for trigger in ErrorSheetTrigger.allCases {
        expectEqual(decide(.silent, trigger, .error, unread: 0), .nothing,
                    "silent says nothing (trigger \(trigger.rawValue))")
        expectEqual(decide(.silent, trigger, .error, unread: 4), .nothing,
                    "silent stays silent however many are unread (trigger \(trigger.rawValue))")
        expectEqual(decide(.notification, trigger, .error, unread: 0), .notification,
                    "notification posts one (trigger \(trigger.rawValue))")
        expectEqual(decide(.banner, trigger, .error, unread: 7), .banner,
                    "banner never escalates to the sheet (trigger \(trigger.rawValue))")
        expectEqual(decide(.banner, trigger, .cancelled, unread: 0), .nothing,
                    "banner style says nothing for a cancellation (trigger \(trigger.rawValue))")
    }
    // The cancel-dialog setting wins over every style.
    for style in FailureAlertStyle.allCases {
        expectEqual(decide(style, .firstFailure, .cancelled, unread: 0, cancelDialog: false), .nothing,
                    "\(style.rawValue): a silenced cancellation says nothing")
    }
}

private func testLabels() {
    expectEqual(FailureAlertStyle.allCases.count, 4, "four alert styles")
    expectEqual(ErrorSheetTrigger.allCases.count, 3, "three sheet triggers")
    for style in FailureAlertStyle.allCases { expectEqual(style.displayLabel.isEmpty, false, "\(style.rawValue) has a label") }
    for trigger in ErrorSheetTrigger.allCases { expectEqual(trigger.displayLabel.isEmpty, false, "\(trigger.rawValue) has a label") }
}

func runTests() {
    testDefaultsReproduceTodaysBehaviour()
    testTrigger()
    testStyles()
    testLabels()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
