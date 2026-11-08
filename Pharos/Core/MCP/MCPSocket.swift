import Darwin
import Foundation

/// Where the running app listens for MCP connections, and how to reach it.
///
/// `~/Library/Application Support/<bundle id>/MCP/pharos.sock`. The folder is
/// the app's own (a re-identified test copy gets its own), the `MCP` folder is
/// 0700 and the socket 0600, so only this user's processes can open it; the
/// server also checks the peer's user id. There is no TCP port: nothing on the
/// network, and no web page, can reach it.
enum MCPSocketPath {

    static func directory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(bundleIdentifier ?? "com.pharos.client")
            .appendingPathComponent("MCP")
    }

    static func socket(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        // `PHAROS_MCP_SOCKET` points the bridge and the app at another socket
        // (scripts/test-mcp-socket.sh, a second build side by side).
        if let override = ProcessInfo.processInfo.environment["PHAROS_MCP_SOCKET"], !override.isEmpty {
            return override
        }
        return directory(bundleIdentifier: bundleIdentifier).appendingPathComponent("pharos.sock").path
    }
}

enum MCPSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)
    case inUse(String)

    var description: String {
        switch self {
        case let .pathTooLong(p): return "The socket path is too long: \(p)"
        case let .system(what, err): return "\(what): \(String(cString: strerror(err)))"
        case let .inUse(p): return "Another copy of Pharos is already listening at \(p)"
        }
    }
}

/// Low-level socket helpers shared by the server and the bridge.
enum MCPSocketIO {

    static func address(_ path: String) throws -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw MCPSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
        addr.sun_len = UInt8(truncatingIfNeeded: length)
        return (addr, length)
    }

    /// A connected socket to `path`, or nil when nothing listens there.
    static func connect(to path: String) -> Int32? {
        guard let (addr, length) = try? address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        var a = addr
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    /// A write to a closed peer returns EPIPE instead of killing the process.
    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Write all of `data`. False when the peer is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                p += n
                left -= n
            }
            return true
        }
    }
}

/// Splits a byte stream into lines. A line longer than `maxLine` is an error:
/// one JSON-RPC message never needs megabytes.
struct MCPLineBuffer {
    static let maxLine = 16 * 1024 * 1024
    private var pending = Data()

    /// Lines completed by `chunk`, without their newline. Nil when a line grew
    /// past the limit.
    mutating func append(_ chunk: Data) -> [String]? {
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        if pending.count > Self.maxLine { return nil }
        return lines
    }
}

/// The app's end: listens on the socket and gives each connection its own
/// `MCPSession`. Each request runs in its own task, so a `run_card` waiting
/// on a long query does not hold up a `list_cards`.
final class MCPSocketServer {

    final class Connection {
        let id = UUID().uuidString
        let fd: Int32
        let session: MCPSession
        fileprivate var source: DispatchSourceRead?
        fileprivate var buffer = MCPLineBuffer()
        fileprivate let writeQueue: DispatchQueue
        fileprivate var closed = false

        init(fd: Int32, session: MCPSession) {
            self.fd = fd
            self.session = session
            writeQueue = DispatchQueue(label: "com.pharos.mcp.write.\(fd)")
        }
    }

    let path: String
    private let makeSession: (MCPAppIdentity?) -> MCPSession
    /// The app at the other end of an accepted socket. The tests replace it.
    private let identify: (Int32) -> MCPAppIdentity?
    private let queue = DispatchQueue(label: "com.pharos.mcp.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [String: Connection] = [:]

    /// The open connections changed: their clients, in no order. Called on
    /// the server's queue.
    var onConnectionsChanged: (([MCPClientInfo]) -> Void)?

    init(path: String, identify: @escaping (Int32) -> MCPAppIdentity? = MCPAppIdentifier.forPeer,
         makeSession: @escaping (MCPAppIdentity?) -> MCPSession) {
        self.path = path
        self.identify = identify
        self.makeSession = makeSession
    }

    deinit { stop() }

    var isListening: Bool { queue.sync { listenFD >= 0 } }

    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    private func startOnQueue() throws {
        guard listenFD < 0 else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Tighten a folder an older build (or the user) made looser.
        chmod(dir, 0o700)

        // A socket file left by a copy that crashed is removed; one a live
        // copy answers on is not.
        if FileManager.default.fileExists(atPath: path) {
            if let fd = MCPSocketIO.connect(to: path) {
                close(fd)
                throw MCPSocketError.inUse(path)
            }
            unlink(path)
        }

        let (addr, length) = try MCPSocketIO.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system("socket", errno) }
        var a = addr
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        umask(previous)
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw MCPSocketError.system("bind \(path)", err)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw MCPSocketError.system("listen", err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    /// Close every connection, stop listening and remove the socket file.
    func stop() {
        queue.sync {
            for connection in connections.values { closeOnQueue(connection, notify: false) }
            connections.removeAll()
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
                unlink(path)
            }
        }
        onConnectionsChanged?([])
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Only this user. The folder's 0700 already keeps others out;
            // this is the check that does not depend on it.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            MCPSocketIO.noSigPipe(fd)
            // BSD hands the listener's O_NONBLOCK to the accepted socket. Reads
            // wait for the source anyway; writes must block (on the write
            // queue), or a large response would stop at EAGAIN.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            // Read now, while the bridge (and the app that launched it) runs.
            let connection = Connection(fd: fd, session: makeSession(identify(fd)))
            connection.session.onInitialize = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.notifyChanged() }
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.read(connection)
            }
            connection.source = source
            connections[connection.id] = connection
            source.resume()
            notifyChanged()
        }
    }

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { Darwin.read(connection.fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            closeOnQueue(connection, notify: true)
            return
        }
        guard let lines = connection.buffer.append(Data(chunk[0..<n])) else {
            closeOnQueue(connection, notify: true)
            return
        }
        for line in lines {
            let session = connection.session
            Task.detached { [weak self, weak connection] in
                guard let response = await session.handle(line: line), let connection else { return }
                self?.send(response, on: connection)
            }
        }
    }

    private func send(_ line: String, on connection: Connection) {
        connection.writeQueue.async {
            guard !connection.closed else { return }
            MCPSocketIO.writeAll(connection.fd, Data((line + "\n").utf8))
        }
    }

    private func closeOnQueue(_ connection: Connection, notify: Bool) {
        connection.source?.cancel()
        connection.source = nil
        connection.writeQueue.sync {
            guard !connection.closed else { return }
            connection.closed = true
            close(connection.fd)
        }
        connections[connection.id] = nil
        if notify { notifyChanged() }
    }

    private func notifyChanged() {
        let clients = connections.values.map { $0.session.client }
        onConnectionsChanged?(clients)
    }
}
