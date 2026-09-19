import AppKit

/// Asks for a password when a connect attempt had none to dial with.
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
            let name = DisplayEscape.escapedTrimmed(config.name)
            prompting.insert(id)
            Task { @MainActor in
                let outcome = await DeviceOwnerGate.authenticate(
                    reason: String(localized: "connect to \(name)"))
                self.prompting.remove(id)
                switch outcome {
                case .authenticated:
                    // One proof covers the sheet and the reconnect behind it.
                    AppStateManager.shared.noteGatePassed(for: config.id)
                    self.present(config)
                case .cancelled:
                    break
                case .failed(let reason):
                    Log.state.error("Password prompt gate refused: \(reason, privacy: .public)")
                }
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
