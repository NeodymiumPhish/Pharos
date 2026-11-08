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

    /// The app behind the process at the other end of socket `fd`.
    static func forPeer(_ fd: Int32) -> MCPAppIdentity? {
        guard let pid = peerPid(fd) else { return nil }
        return identify(bridgePid: pid, facts: systemFacts)
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
