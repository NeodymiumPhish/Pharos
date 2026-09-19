import Foundation

/// Which connections Pharos opens for itself at launch, and in what order.
///
/// Pure and Foundation-only, so `scripts/test-launch-connect-policy.sh` can
/// pose every case without a launch, a window or a database. The decision is
/// small but it is worth having in one testable place: getting it wrong means
/// either a connection the user did not ask for, or several authentication
/// prompts arriving on top of each other before the first window is usable.
enum LaunchConnectPolicy {

    /// As much of a `Connection` as the decision needs.
    struct Candidate: Equatable {
        let id: String
        let name: String
        /// The per-connection "Connect when Pharos starts" flag.
        let connectOnLaunch: Bool
        /// Whether this connection is already up — a session restore may have
        /// opened it before this runs.
        let isAlreadyConnected: Bool
        /// Whether opening it will put a Touch ID prompt on screen.
        let requiresAuthentication: Bool

        init(id: String, name: String, connectOnLaunch: Bool,
             isAlreadyConnected: Bool = false, requiresAuthentication: Bool = false) {
            self.id = id
            self.name = name
            self.connectOnLaunch = connectOnLaunch
            self.isAlreadyConnected = isAlreadyConnected
            self.requiresAuthentication = requiresAuthentication
        }
    }

    /// The connections to open, in the order to open them.
    ///
    /// The order is the caller's order — the Connections Manager's own sort —
    /// with one change: every connection that will ask for Touch ID goes
    /// LAST, after the ones that will not. A gated connection blocks on a
    /// system prompt, and putting those first would hold up connections that
    /// could have been up already while the user reaches for the reader.
    ///
    /// The relative order within each group is kept, so the list stays
    /// predictable rather than merely fast.
    static func connectionsToOpen(_ candidates: [Candidate]) -> [Candidate] {
        let wanted = candidates.filter { $0.connectOnLaunch && !$0.isAlreadyConnected }
        return wanted.filter { !$0.requiresAuthentication } + wanted.filter(\.requiresAuthentication)
    }

    /// Whether any of them will put an authentication prompt on screen. The
    /// caller opens those ONE AT A TIME for that reason; with none, they can
    /// all go at once.
    static func needsSerialPrompts(_ toOpen: [Candidate]) -> Bool {
        toOpen.contains { $0.requiresAuthentication }
    }
}
