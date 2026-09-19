import Foundation

/// The pure rules behind the SSH Tunnel section of the Connections Manager.
///
/// `ConnectionsManagerVC` cannot be compiled on its own — it reaches
/// `AppStateManager` and through it the whole FFI — so anything decided inside
/// it is unreachable by the standalone `swiftc` harnesses this project tests
/// with. The DECISIONS therefore live here, as functions of values, and the
/// view controller only applies them to controls.
enum SshTunnelForm {

    // MARK: Row visibility

    /// Which of the section's optional rows the form shows, and what the
    /// secret row is called.
    struct Visibility: Equatable {
        /// Every row below the "Connect through an SSH tunnel" checkbox.
        var tunnelRows: Bool
        /// The key-file row, for `.keyFile` only.
        var keyFileRow: Bool
        /// The passphrase or password row. The agent needs no secret.
        var secretRow: Bool
        /// The "Remember the SSH secret in the keychain" row.
        ///
        /// It follows the secret row exactly, and is HIDDEN rather than
        /// disabled for the agent. Two reasons. The section already hides the
        /// rows that do not apply — the key file for a password tunnel, the
        /// secret for the agent — so a lone disabled row would be the odd one
        /// out. And a disabled checkbox still SHOWS a state: ticked, it would
        /// tell an agent user that Pharos is keeping a secret it does not
        /// have.
        var rememberSecretRow: Bool
        /// The secret row's label. A key file takes a PASSPHRASE and a
        /// password mode takes a PASSWORD; one word for both would be wrong
        /// in one of the two.
        var secretLabel: String
    }

    static func visibility(enabled: Bool, auth: SshAuthMethod) -> Visibility {
        guard enabled else {
            return Visibility(tunnelRows: false, keyFileRow: false,
                              secretRow: false, rememberSecretRow: false,
                              secretLabel: secretLabel(for: auth))
        }
        let needsSecret = auth != .agent
        return Visibility(
            tunnelRows: true,
            keyFileRow: auth == .keyFile,
            secretRow: needsSecret,
            rememberSecretRow: needsSecret,
            secretLabel: secretLabel(for: auth))
    }

    private static func secretLabel(for auth: SshAuthMethod) -> String {
        auth == .keyFile
            ? String(localized: "Passphrase")
            : String(localized: "Password")
    }

    // MARK: Form to model

    /// The raw values the section's controls hold.
    struct Fields {
        var enabled: Bool
        var host: String
        var port: String
        var user: String
        var auth: SshAuthMethod
        var keyPath: String
        var secret: String
        var acceptNewHostKeys: Bool
        /// The "Remember the SSH secret in the keychain" checkbox. It starts
        /// ON, which is what every tunnel written before it did.
        var rememberSecret: Bool
        /// False while the secret field shows the mask rather than the stored
        /// secret. The mask is not a secret, so it must never be written back.
        var secretRevealed: Bool

        init(enabled: Bool = false, host: String = "", port: String = "22",
             user: String = "", auth: SshAuthMethod = .agent, keyPath: String = "",
             secret: String = "", acceptNewHostKeys: Bool = false,
             rememberSecret: Bool = true,
             secretRevealed: Bool = true) {
            self.enabled = enabled
            self.host = host
            self.port = port
            self.user = user
            self.auth = auth
            self.keyPath = keyPath
            self.secret = secret
            self.acceptNewHostKeys = acceptNewHostKeys
            self.rememberSecret = rememberSecret
            self.secretRevealed = secretRevealed
        }
    }

    /// The tunnel the form describes, or `nil` when the checkbox is off.
    ///
    /// `existing` is the tunnel the draft already holds. It supplies the two
    /// values the form cannot: the secret while the field is masked, and the
    /// port while the port field holds something that is not a number.
    static func tunnel(from fields: Fields, existing: SshTunnelConfig?) -> SshTunnelConfig? {
        guard fields.enabled else { return nil }
        let user = fields.user.trimmingCharacters(in: .whitespaces)
        let keyPath = fields.keyPath.trimmingCharacters(in: .whitespaces)
        return SshTunnelConfig(
            host: fields.host,
            port: UInt16(fields.port) ?? existing?.port ?? 22,
            // An empty user is not a user named "": it means "let
            // ~/.ssh/config choose", which is a different command line.
            user: user.isEmpty ? nil : user,
            auth: fields.auth,
            keyPath: keyPath.isEmpty ? nil : keyPath,
            secret: fields.secretRevealed ? fields.secret : (existing?.secret ?? ""),
            acceptNewHostKeys: fields.acceptNewHostKeys,
            // Carried whatever the mode is. The agent hides this row rather
            // than resetting it, so a user who moves to the agent and back
            // finds the answer they gave.
            rememberSecret: fields.rememberSecret)
    }

    // MARK: Derived text

    /// The tunnel's part of the connection fingerprint, which decides whether
    /// a fetched schema list still describes this server.
    ///
    /// Everything here changes WHICH machine the connection reaches. The
    /// secret is deliberately absent: a new passphrase for the same key
    /// reaches the same server, and this string is used as a dictionary key,
    /// which is no place for a secret.
    static func fingerprint(_ tunnel: SshTunnelConfig?) -> String {
        guard let tunnel else { return "none" }
        return "\(tunnel.host):\(tunnel.port)@\(tunnel.user ?? "")/\(tunnel.auth.rawValue)/\(tunnel.keyPath ?? "")/\(tunnel.acceptNewHostKeys)"
    }

    /// "via <bastion>", for the toolbar tooltip, or `nil` when the connection
    /// is direct.
    ///
    /// The host is a stored string shown as a label, so the caller passes the
    /// same escape every other name in those places goes through.
    static func viaPhrase(_ tunnel: SshTunnelConfig?, escape: (String) -> String) -> String? {
        guard let tunnel else { return nil }
        return "via \(escape(tunnel.host))"
    }

    /// The same thing as a separated suffix, for the connections list row,
    /// where it follows "host:port · database". Empty for a direct connection.
    static func viaSuffix(_ tunnel: SshTunnelConfig?, escape: (String) -> String) -> String {
        guard let phrase = viaPhrase(tunnel, escape: escape) else { return "" }
        return " · " + phrase
    }
}

