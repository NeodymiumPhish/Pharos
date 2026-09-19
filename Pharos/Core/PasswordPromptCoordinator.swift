import AppKit

/// Asks for a password when a connect attempt had none to dial with, and for
/// the SSH tunnel secret when a bastion refused the identity it was given.
///
/// It sits on `AppStateManager.connectionStatusDidChange` — the notification
/// every connect outcome posts — rather than inside the connect path itself.
/// That keeps the whole feature in files of its own, and it is the same seam:
/// the notification is posted from exactly where a failure is recorded.
///
/// The ORDER matters and is the reason this is not simply "show a sheet on any
/// failure":
///
///  * `PasswordAvailability` decides first. A failure on a connection that HAS
///    a password is about the host, the port, the database or the server, and
///    a password sheet in front of it would be a wrong answer confidently
///    given.
///  * A record with `requiresAuthentication` is put through `DeviceOwnerGate`
///    before the sheet is shown. The sheet must never become a way to open a
///    gated connection without Touch ID — and this observer also fires when
///    the gate itself refused, where no gate has been passed at all.
///
/// Nothing here logs a password, and no password reaches an error string.
@MainActor
final class PasswordPromptCoordinator {

    static let shared = PasswordPromptCoordinator()

    /// Connections the user has given a password for this run. It mirrors the
    /// core's own process-only map; the two are cleared together.
    private var sessionPasswords: Set<String> = []

    /// Connections with a sheet on screen, so a second failure cannot stack a
    /// second sheet on the first.
    private var prompting: Set<String> = []

    private var observer: NSObjectProtocol?

    private init() {}

    /// Begin watching. Idempotent: every main window calls it, and only the
    /// first does anything.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AppStateManager.connectionStatusDidChange, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let id = note.userInfo?["connectionId"] as? String else { return }
                PasswordPromptCoordinator.shared.statusChanged(id)
            }
        }
    }

    /// Forget which connections have a typed password. Called beside the core's
    /// own `clearSessionPasswords`, so the two never disagree — if they did,
    /// this side would decide "it has one" and connect straight into the same
    /// failure instead of asking.
    func forgetSessionPasswords() {
        sessionPasswords.removeAll()
    }

    // MARK: - The decision

    private func statusChanged(_ id: String) {
        let state = AppStateManager.shared
        guard state.status(for: id) == .error,
              !prompting.contains(id),
              let config = state.connections.first(where: { $0.id == id })
        else { return }

        // The TUNNEL is asked about FIRST, and it answers the whole failure
        // when it answers at all. The tunnel opens before the pool, so a
        // bastion that refused us means the database was never reached — and
        // a password sheet for a database nothing has spoken to yet would be
        // the wrong question.
        switch SshSecretPrompt.decide(failure: state.connectionError(for: id),
                                      auth: config.sshTunnel?.auth,
                                      requiresAuthentication: config.requiresAuthentication,
                                      gateIsFresh: state.gateIsFresh(for: id)) {
        case .prompt:
            presentSshSecret(config)
            return
        case .authenticateThenPrompt:
            gateThen(config) { [weak self] in self?.presentSshSecret(config) }
            return
        case .ignore:
            break
        }

        // `config.password` is what the core handed over, and the core fills it
        // from the Keychain cache at startup. A record that remembers nothing
        // arrives with it empty, which is exactly the question being asked.
        let decision = PasswordAvailability.decide(
            hasSessionPassword: sessionPasswords.contains(id),
            hasKeychainPassword: !config.password.isEmpty,
            rememberPassword: config.rememberPassword,
            requiresAuthentication: config.requiresAuthentication)

        switch decision {
        case .connect:
            // The failure is not about the password. Leave the reason the
            // connect path already recorded on screen.
            return
        case .refuse:
            // The Keychain still holds a password for a record that says it
            // keeps none, so the delete at save time did not happen. Say so
            // rather than quietly using it or quietly asking for another.
            Log.state.error(
                "Connection \(id, privacy: .public) has a stored password but does not remember one; the keychain delete did not take effect")
            return
        case .prompt:
            present(config)
        case .authenticateThenPrompt:
            gateThen(config) { [weak self] in self?.present(config) }
        }
    }

    /// Put the record's Touch ID gate in front of `sheet`.
    ///
    /// The id is held in `prompting` for the length of the gate, so a second
    /// failure arriving while the system prompt is up cannot raise a second
    /// one behind it. A pass is recorded with `noteGatePassed`, so the ONE
    /// proof covers the sheet and the reconnect behind it instead of raising
    /// a fresh prompt for each — see `DeviceOwnerGateRecency`.
    private func gateThen(_ config: ConnectionConfig, sheet: @escaping () -> Void) {
        let id = config.id
        let name = DisplayEscape.escapedTrimmed(config.name)
        prompting.insert(id)
        Task { @MainActor in
            let outcome = await DeviceOwnerGate.authenticate(
                reason: String(localized: "connect to \(name)"))
            self.prompting.remove(id)
            switch outcome {
            case .authenticated:
                AppStateManager.shared.noteGatePassed(for: id)
                sheet()
            case .cancelled:
                break
            case .failed(let reason):
                Log.state.error("Password prompt gate refused: \(reason, privacy: .public)")
            }
        }
    }

    // MARK: - The sheet

    private func present(_ config: ConnectionConfig) {
        guard !prompting.contains(config.id),
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let host = window.contentViewController
        else { return }

        prompting.insert(config.id)
        let id = config.id
        let sheet = PasswordPromptSheet(
            name: config.name,
            address: "\(config.username)@\(config.host):\(config.port)/\(config.database)",
            remembersAlready: config.rememberPassword
        ) { [weak self] outcome in
            guard let self else { return }
            self.prompting.remove(id)
            guard case .connect(let password, let remember) = outcome else { return }
            self.use(password, remember: remember, for: id)
        }
        host.presentAsSheet(sheet)
    }

    /// Ask for the SSH tunnel's secret.
    ///
    /// The sheet names the BASTION, not the database: a user who has both
    /// prompts in one session must be able to tell them apart, and the secret
    /// being asked for belongs to the SSH server.
    private func presentSshSecret(_ config: ConnectionConfig) {
        guard !prompting.contains(config.id),
              let tunnel = config.sshTunnel,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let host = window.contentViewController
        else { return }

        prompting.insert(config.id)
        let id = config.id
        let target = [tunnel.user.map { "\($0)@" } ?? "", tunnel.host, ":\(tunnel.port)"].joined()
        let sheet = PasswordPromptSheet(
            purpose: .sshSecret(auth: tunnel.auth, sshTarget: target),
            name: config.name,
            address: target,
            remembersAlready: tunnel.rememberSecret
        ) { [weak self] outcome in
            guard let self else { return }
            self.prompting.remove(id)
            guard case .connect(let secret, let remember) = outcome else { return }
            self.useSshSecret(secret, remember: remember, for: id)
        }
        host.presentAsSheet(sheet)
    }

    /// Put the typed tunnel secret to work.
    ///
    /// With "Remember in the Keychain" ticked the record is saved first, which
    /// is what writes the secret under `<id>/ssh` and turns the tunnel's own
    /// `rememberSecret` on. Without it, nothing is written anywhere: the core
    /// keeps it in the map that dies with the process.
    ///
    /// The retry is the WHOLE connect. The tunnel opens before the pool, so
    /// there is no shorter path back.
    private func useSshSecret(_ secret: String, remember: Bool, for id: String) {
        let state = AppStateManager.shared

        if remember, var config = state.connections.first(where: { $0.id == id }),
           var tunnel = config.sshTunnel {
            tunnel.secret = secret
            tunnel.rememberSecret = true
            config.sshTunnel = tunnel
            state.saveConnection(config)
        }

        Task { @MainActor in
            do {
                // This is what puts the secret in the core's session map, so
                // every later attempt this run finds it too.
                _ = try await PharosCore.connect(connectionId: id, sshSecret: secret)
            } catch {
                // The reason belongs to the connect below, which records it in
                // the state the UI reads. Nothing is logged here that could
                // carry the secret.
                Log.state.error("Connect with a typed SSH secret failed")
            }
            state.connect(id: id)
        }
    }

    /// Put the typed password to work.
    ///
    /// With "Remember in the Keychain" ticked the record is saved first, which
    /// is what writes the password to the Keychain and turns the record's own
    /// `rememberPassword` on. Without it, nothing is written anywhere: the core
    /// keeps it in the map that dies with the process.
    private func use(_ password: String, remember: Bool, for id: String) {
        let state = AppStateManager.shared
        sessionPasswords.insert(id)

        if remember, var config = state.connections.first(where: { $0.id == id }) {
            config.password = password
            config.rememberPassword = true
            state.saveConnection(config)
        }

        Task { @MainActor in
            do {
                // This is what puts the password in the core's session map, so
                // every later attempt this run finds it too.
                _ = try await PharosCore.connect(connectionId: id, password: password)
            } catch {
                // The reason belongs to the connect below, which records it in
                // the state the UI reads. Nothing is logged here that could
                // carry the password.
                Log.state.error("Connect with a typed password failed")
            }
            // And this is what makes the app's own status agree. The pool is
            // already open by now, so the core answers immediately.
            state.connect(id: id)
        }
    }
}
