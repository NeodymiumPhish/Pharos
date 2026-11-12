import Darwin
import Foundation
import Security

/// Which app launched `Pharos --mcp`, told by its code signature.
///
/// A client names itself in `initialize`, but that is its own claim: any
/// program can say it is LM Studio. What it cannot fake is LM Studio's
/// signature. So the server takes the bridge's process id from the socket,
/// walks up its parent processes past Apple's own programs (the shells and
/// helpers a client launches servers through), and reads the first other
/// program's signature: its Developer ID team and the app bundle it sits in.
/// A program with no team (unsigned, or signed ad hoc) is named by its path.
/// A chain of Apple programs only — `Pharos --mcp` typed in Terminal — has no
/// app to name, and gets no identity.
///
/// The walk starts from the bridge, so the process on the socket must BE the
/// bridge: this copy of Pharos, by its own code signature (`peerIsPharos`).
/// Any program of this user can open the socket, and one that connected
/// directly could arrange its own parent: fork, and have the parent become
/// an approved app's real binary. That is refused. What is left is a program
/// that does the same and then runs the real `Pharos --mcp` as the child:
/// nothing here can tell that from the app launching it, and a program that
/// can do it already runs as this user and reads this user's files.
///
/// The walk is `identify(bridgePid:facts:)`, over facts it is handed, so
/// scripts/test-mcp-access-policy.sh tests it with made-up processes;
/// `systemFacts` reads the real ones.
enum MCPAppIdentifier {

    /// One process, as the walk needs it.
    struct ProcessFacts: Equatable {
        enum Signer: Equatable {
            /// Signed by Apple: a shell, Terminal, python3. Walked past.
            case apple
            /// A Developer ID team, and the signature's identifier.
            case team(id: String, identifier: String, summary: String?)
            /// No team: unsigned, or signed ad hoc.
            case unsigned
        }
        let parent: pid_t
        let path: String?
        let signer: Signer
    }

    /// The app that launched the process `bridgePid` (the bridge itself is
    /// Pharos, and is not looked at), or nil when none can be named.
    static func identify(bridgePid: pid_t, facts: (pid_t) -> ProcessFacts?,
                         bundle: (String) -> (id: String, name: String)? = appBundle(containing:)) -> MCPAppIdentity? {
        guard let bridge = facts(bridgePid) else { return nil }
        var pid = bridge.parent
        var seen: Set<pid_t> = [bridgePid]
        while pid > 1, seen.insert(pid).inserted, seen.count <= 64 {
            guard let process = facts(pid) else { return nil }
            switch process.signer {
            case .apple:
                pid = process.parent
            case let .team(team, identifier, summary):
                let app = process.path.flatMap(bundle)
                return MCPAppIdentity(id: "team:\(team):\(app?.id ?? identifier)",
                                      name: app?.name ?? identifier,
                                      detail: summary ?? team, signed: true)
            case .unsigned:
                guard let path = process.path else { return nil }
                let app = bundle(path)
                return MCPAppIdentity(id: "path:\(path)",
                                      name: app?.name ?? (path as NSString).lastPathComponent,
                                      detail: path, signed: false)
            }
        }
        return nil
    }

    /// The outermost `.app` bundle around `path`: a helper inside Claude.app
    /// is Claude.
    static func appBundle(containing path: String) -> (id: String, name: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = parts[...i].joined(separator: "/")
        guard let bundle = Bundle(path: bundlePath), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return (id, name)
    }

    /// The app behind the process at the other end of socket `fd`, when
    /// that process is Pharos's own bridge.
    static func forPeer(_ fd: Int32) -> MCPAppIdentity? {
        guard let pid = peerPid(fd) else { return nil }
        guard peerIsPharos(fd) else { return nil }
        return identify(bridgePid: pid, facts: systemFacts)
    }

    /// Whether the process at the other end of `fd` runs this app's own
    /// code: it satisfies the designated requirement of the running Pharos.
    /// For a Developer ID build that is the same team and identifier; for an
    /// ad hoc build (every release so far) it is the same binary, so after
    /// an update the bridge is refused until Pharos is reopened.
    ///
    /// The peer is named by its audit token, not its pid: a pid can be
    /// reused by another process between the connect and the check.
    static func peerIsPharos(_ fd: Int32) -> Bool {
        #if DEBUG
        // A debug build is run from Xcode beside an installed copy, whose
        // bridge is another binary; the developer's own machine.
        return true
        #else
        guard let requirement = ownRequirement, let token = peerAuditToken(fd) else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        #endif
    }

    /// The designated requirement of the running app.
    private static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    /// The peer's audit token (`LOCAL_PEERTOKEN`), as the bytes
    /// `kSecGuestAttributeAudit` takes.
    static func peerAuditToken(_ fd: Int32) -> Data? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    static func peerPid(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// A running process's parent, executable and signer.
    static func systemFacts(_ pid: pid_t) -> ProcessFacts? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        return ProcessFacts(parent: info.kp_eproc.e_ppid, path: path, signer: signer(of: pid))
    }

    private static let appleAnchor: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        return requirement
    }()

    private static func signer(of pid: pid_t) -> ProcessFacts.Signer {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              // The running code must still match its signature.
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return .unsigned }
        if SecCodeCheckValidity(code, [], appleAnchor) == errSecSuccess { return .apple }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return .unsigned }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? team
        let summary = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
            .flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return .team(id: team, identifier: identifier, summary: summary)
    }
}
