// Standalone test runner for ScrollBarPolicy — the rule behind Settings ▸
// General ▸ "Always show scroll bars in the editor and results". Compiled by
// scripts/test-scroll-bar-policy.sh with the policy alone: the setting comes
// in as a publisher, so no AppStateManager (and no FFI) is needed.
import AppKit
import Combine

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

/// Drains the main run loop so `receive(on: RunLoop.main)` deliveries land.
private func drain() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // --- the pure rule ---
    let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    sv.hasVerticalScroller = true
    ScrollBarPolicy.apply(alwaysVisible: true, to: sv)
    expectEqual(sv.scrollerStyle, .legacy, "on → legacy scrollers")
    expectTrue(!sv.autohidesScrollers, "on → scrollers never hide")
    ScrollBarPolicy.apply(alwaysVisible: false, to: sv)
    expectEqual(sv.scrollerStyle, NSScroller.preferredScrollerStyle, "off → the system's preferred style")
    expectTrue(sv.autohidesScrollers, "off → scrollers hide when nothing overflows")

    // --- the live object: follows the setting as it changes ---
    let setting = CurrentValueSubject<Bool, Never>(true)
    let live = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    live.hasVerticalScroller = true
    let policy = ScrollBarPolicy(scrollView: live, alwaysVisible: setting.eraseToAnyPublisher())
    drain()
    expectEqual(live.scrollerStyle, .legacy, "the initial value is applied")
    expectTrue(!live.autohidesScrollers, "…including the autohide half")
    setting.send(false)
    drain()
    expectEqual(live.scrollerStyle, NSScroller.preferredScrollerStyle, "a flip to off follows the system")
    expectTrue(live.autohidesScrollers, "…and lets the scrollers hide")
    setting.send(true)
    drain()
    expectEqual(live.scrollerStyle, .legacy, "a flip back to on pins legacy scrollers again")

    // --- the system preference changing re-applies while following ---
    setting.send(false)
    drain()
    // Knock the scroll view off the rule by hand, as an explicit style set
    // elsewhere would; the preference notification must put it back.
    live.autohidesScrollers = false
    NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    drain()
    expectTrue(live.autohidesScrollers, "the preference notification re-applies the rule")
    expectEqual(live.scrollerStyle, NSScroller.preferredScrollerStyle, "…with the (possibly new) preferred style")

    // --- the policy does not keep its scroll view alive ---
    var weakScroll: NSScrollView?
    var heldPolicy: ScrollBarPolicy?
    autoreleasepool {
        let s = NSScrollView()
        weakScroll = s
        heldPolicy = ScrollBarPolicy(scrollView: s, alwaysVisible: Just(true).eraseToAnyPublisher())
    }
    _ = heldPolicy
    // `weakScroll` is a strong local; re-check through a weak box instead.
    weak var box = weakScroll
    weakScroll = nil
    expectTrue(box == nil, "the policy holds its scroll view weakly")

    _ = policy
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
