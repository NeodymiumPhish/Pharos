import Foundation

/// What to do about an SSH tunnel secret after a connect attempt failed.
///
/// The sibling of `PasswordAvailability`, for the other secret. The two are
/// asked in different ways and that difference is the point:
///
///  * The DATABASE password is judged BEFORE dialling, from what the record
///    carries — there is nothing to attempt if there is no password.
///  * The TUNNEL secret is judged AFTER a failure, from the failure itself.
///    `ssh` decides whether an identity was accepted, and a key-file tunnel
///    whose key needs no passphrase is perfectly normal with an empty secret.
///    Only the bastion can say the secret is missing or wrong, and it says so
///    through `SshTunnelAuthError`'s marker.
///
/// Foundation only, and pure. The Touch ID gate, the sheet and the FFI are the
/// caller's business; this only says which of them is owed.
enum SshSecretPrompt {

    enum Decision: Equatable {
        /// Leave the failure alone. It is not a question a secret answers.
        case ignore
        /// Ask for the tunnel secret.
        case prompt
        /// Ask for the tunnel secret, but prove the device owner is present
        /// FIRST. A gated connection must not become openable by anyone who
        /// can type into a sheet.
        case authenticateThenPrompt
    }

    /// - Parameters:
    ///   - failure: the reason the connect attempt recorded, exactly as the
    ///     core gave it, marker and all.
    ///   - auth: the tunnel's authentication mode, or `nil` when the
    ///     connection has no tunnel.
    ///   - requiresAuthentication: the record's Touch ID gate.
    ///   - gateIsFresh: the gate for this connection passed moments ago, so
    ///     one proof already covers this piece of work. See
    ///     `DeviceOwnerGateRecency`.
    static func decide(failure: String?,
                       auth: SshAuthMethod?,
                       requiresAuthentication: Bool,
                       gateIsFresh: Bool) -> Decision {
        // Not the bastion refusing us. A pool error, a bad host, a host key:
        // a secret sheet in front of any of those is a wrong answer
        // confidently given.
        guard SshTunnelAuthError.isAuthFailure(failure) else { return .ignore }

        // No tunnel at all, so the marker cannot be about this connection.
        guard let auth else { return .ignore }

        // The agent holds its own keys and Pharos never has a secret for it.
        // `ssh` can still refuse us — a locked agent, no key loaded — but
        // nothing the user could type here would change that, so asking would
        // waste their time and imply Pharos stores something it does not.
        guard auth != .agent else { return .ignore }

        // One proof covers the gate, the sheet and the reconnect behind it.
        if requiresAuthentication && !gateIsFresh { return .authenticateThenPrompt }
        return .prompt
    }
}
