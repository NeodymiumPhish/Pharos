import Foundation

/// How long a passed Touch ID gate counts for, within one connect attempt.
///
/// The gate exists to prove the device owner is present before a STORED
/// credential is used. Opening one connection can reach `connect(id:)` three
/// times in a few seconds — the first attempt, the password prompt behind it,
/// and the status refresh after the password is typed — and gating each of
/// them shows the user three system prompts in a row for one action. Nothing
/// is proved by the second and third that the first did not prove.
///
/// So a pass is remembered, briefly, and only for the connection it was
/// given for. The window is deliberately short: it is meant to span ONE piece
/// of work, not to keep the gate open while the Mac is unattended. It is not
/// a "remember me" — a later, separate connect attempt is gated again.
///
/// Pure, so `scripts/test-device-owner-gate-recency.sh` can pose the clock.
enum DeviceOwnerGateRecency {

    /// Long enough to cover a gate, a sheet the user types into, and the
    /// reconnect behind it. Short enough that walking away ends it.
    static let window: TimeInterval = 120

    /// Whether a gate passed at `passedAt` still counts at `now`.
    ///
    /// A pass in the FUTURE does not count. That is not paranoia about clock
    /// skew for its own sake: the system clock can move backwards (NTP, a
    /// timezone tool, the user), and a stored future timestamp would
    /// otherwise keep the gate open for as long as the clock stayed behind.
    static func isFresh(passedAt: Date, now: Date = Date(), window: TimeInterval = window) -> Bool {
        let age = now.timeIntervalSince(passedAt)
        return age >= 0 && age < window
    }
}
