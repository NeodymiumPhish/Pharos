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
        if state.status(for: id) == .connected { readOnlyTried.remove(id) }
        guard state.status(for: id) == .error,
              !prompting.contains(id),
              let config = state.connections.first(where: { $0.id == id })
        else { return }

        // A DuckDB record has no password and no tunnel. The one failure it
        // can answer is a file another process holds for writing.
        if config.isDuckDB {
            let failure = state.connectionError(for: id)
            if DuckDBOpenError.isLocked(failure) {
                offerReadOnly(config, failure: failure ?? "")
            } else if DuckDBOpenError.isMissing(failure) {
                // A connect Pharos started on its own (at launch, from a
                // Shortcut) says so in the tab's context row instead.
                if !state.takeQuietConnect(id) { offerMissingFile(config) }
            }
            return
        }

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

    // MARK: - DuckDB lock

    /// Records the user chose "Open Read-Only" for, until that connect ends.
    private var readOnlyTried: Set<String> = []

    /// A DuckDB file another process holds a lock on.
    ///
    /// DuckDB lets one process write a file, OR any number of processes read
    /// it when every one of them opened it read-only. A writer's lock shuts
    /// readers out too (measured with DuckDB 1.5.6). So read-only is OFFERED,
    /// for the case where the other app is itself only reading; when it is
    /// writing, the read-only try meets the same lock, and the user is told
    /// to close the file there instead of being asked again.
    private func offerReadOnly(_ config: ConnectionConfig, failure: String) {
        guard !prompting.contains(config.id) else { return }
        prompting.insert(config.id)
        let id = config.id
        let file = DisplayEscape.escapedTrimmed((config.database as NSString).lastPathComponent)
        let holder = DuckDBOpenError.holderPID(failure).map { String(localized: "Process \(String($0))") }
            ?? String(localized: "Another app")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(file)” is in use by another app.")
        let tried = readOnlyTried.remove(id) != nil
        if tried {
            alert.informativeText = String(localized: "\(holder) has it open for writing, so it cannot be opened, even read-only. Close it in that app, then connect again.")
            alert.addButton(withTitle: String(localized: "OK"))
        } else {
            alert.informativeText = String(localized: "\(holder) holds a lock on it. If that app only reads the file, Pharos can open it read-only too. If it is writing, close the file there first.")
            alert.addButton(withTitle: String(localized: "Open Read-Only"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.prompting.remove(id)
            if !tried, response == .alertFirstButtonReturn {
                self?.readOnlyTried.insert(id)
                AppStateManager.shared.connect(id: id, readOnly: true)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// A DuckDB record whose file is not there. Connect never makes an empty
    /// database in its place, which would look like the user's data had gone
    /// (HIG File management). Locate… follows the file to where it is now;
    /// Create Empty Database is the explicit choice of a new one.
    func offerMissingFile(_ config: ConnectionConfig) {
        guard !prompting.contains(config.id) else { return }
        prompting.insert(config.id)
        let id = config.id
        let file = DisplayEscape.escapedTrimmed((config.database as NSString).lastPathComponent)
        let path = DisplayEscape.escaped(ConnectionConfig.abbreviatingHome(config.database))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(file)” can’t be found.")
        alert.informativeText = String(localized: "There is no file at \(path). It may have been moved, renamed or deleted, or its disk is not connected.")
        alert.addButton(withTitle: String(localized: "Locate…"))
        alert.addButton(withTitle: String(localized: "Create Empty Database"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.prompting.remove(id)
            switch response {
            case .alertFirstButtonReturn: self?.locate(config)
            case .alertSecondButtonReturn: AppStateManager.shared.connect(id: id, create: true)
            default: break
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Choose where a DuckDB record's file is now, store that path in the
    /// SAME record (its tabs, Sessions and history keep pointing at it), and
    /// connect. The name follows the file only while it is still the old
    /// file's name.
    func locate(_ config: ConnectionConfig) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let old = URL(fileURLWithPath: config.database)
        panel.directoryURL = old.deletingLastPathComponent()
        panel.message = String(localized: "Locate “\((config.database as NSString).lastPathComponent)”")
        panel.prompt = String(localized: "Choose")
        let id = config.id
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let manager = AppStateManager.shared
            guard var record = manager.connections.first(where: { $0.id == id }) else { return }
            // A name Pharos gave from the old file follows the new one; a
            // name the user typed stays.
            let others = manager.connections.filter { $0.id != id }
            let oldStem = (old.lastPathComponent as NSString).deletingPathExtension
            if record.name == oldStem || record.name == DuckDBFiles.uniqueName(forPath: old.path, in: others) {
                record.name = DuckDBFiles.uniqueName(forPath: url.path, in: others)
            }
            record.database = DuckDBFiles.canonicalPath(url.path)
            manager.saveConnection(record)
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: record.database))
            manager.connect(id: id)
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
