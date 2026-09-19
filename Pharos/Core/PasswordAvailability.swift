import Foundation

/// What to do about a connection's password before dialling it.
///
/// A connection can reach a connect attempt with its password in one of three
/// places: typed this run and held in the core's process-only map, written in
/// the Keychain, or nowhere at all. The third case used to fail with whatever
/// the server said about a missing or empty password, which reads as a fault
/// rather than as a question. This decides, from the four facts the front end
/// actually holds, whether to dial, to ask, or to do neither.
///
/// Foundation only, and pure. The Touch ID gate, the sheet and the FFI are the
/// caller's business; this only says which of them is owed.
enum PasswordAvailability {

    /// The four facts. Named, because four bare booleans at a call site is a
    /// puzzle and this one has to be read correctly.
    enum Decision: Equatable {
        /// A password is at hand. Dial with it.
        case connect
        /// No password. Ask for one.
        case prompt
        /// No password, and the record is gated. The device owner proves who
        /// they are FIRST, and only then is the sheet shown — a gated
        /// connection must not become openable by anyone who can type a
        /// password into a sheet.
        case authenticateThenPrompt
        /// The Keychain holds a password for a record that says it remembers
        /// none. The save path deletes it, so this state means that delete did
        /// not happen — a locked or refused Keychain. Neither answer is right:
        /// using it would ignore what the user asked for, and asking would
        /// leave the secret sitting there unmentioned. The caller says so
        /// instead.
        case refuse
    }

    /// - Parameters:
    ///   - hasSessionPassword: the core holds one typed this run.
    ///   - hasKeychainPassword: the record arrived carrying a stored password.
    ///   - rememberPassword: the record's own switch.
    ///   - requiresAuthentication: the record's Touch ID gate.
    static func decide(hasSessionPassword: Bool,
                       hasKeychainPassword: Bool,
                       rememberPassword: Bool,
                       requiresAuthentication: Bool) -> Decision {
        // What the user typed this run wins over anything stored. A password
        // re-typed because the stored one had gone stale must not lose to the
        // stale one, and the gate has already been passed to get here.
        if hasSessionPassword { return .connect }

        if hasKeychainPassword {
            return rememberPassword ? .connect : .refuse
        }

        return requiresAuthentication ? .authenticateThenPrompt : .prompt
    }
}
