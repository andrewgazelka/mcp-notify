import Foundation

/// AF_UNIX / SOCK_STREAM accept loop speaking newline-delimited JSON.
///
/// One request per connection: the CLI connects, writes, reads one line, and
/// closes. Messages are ~200 bytes, so framing beyond a newline would be
/// ceremony, and this way `nc -U` is a working debugger.
final class SocketServer: @unchecked Sendable {
    private let path: String
    private var listenFD: Int32 = -1
    private let handler: @Sendable (Request) async -> Response
    private let log: @Sendable (String) -> Void

    init(path: String,
         log: @escaping @Sendable (String) -> Void,
         handler: @escaping @Sendable (Request) async -> Response) {
        self.path = path
        self.handler = handler
        self.log = log
    }

    /// True if another live instance already owns the socket.
    ///
    /// Connecting first is what makes a stale socket file self-healing: a
    /// refused connection means the owner is gone and the path is ours to
    /// unlink, while a successful one means we should quietly exit.
    static func isLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard fillPath(&addr, path) else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return rc == 0
    }

    private static func fillPath(_ addr: inout sockaddr_un, _ path: String) -> Bool {
        let bytes = Array(path.utf8)
        // sun_path is 104 bytes on Darwin. Our default is ~48, but a long $HOME
        // or an XDG override could overflow, and a truncated path binds to the
        // WRONG socket silently.
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return true
    }

    func bindAndListen() throws {
        if Self.isLive(path: path) { throw ServerError.alreadyRunning }
        unlink(path) // stale file from a SIGKILL

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ServerError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard Self.fillPath(&addr, path) else { throw ServerError.pathTooLong(path) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard rc == 0 else { throw ServerError.bindFailed(errno) }
        guard listen(listenFD, 128) == 0 else { throw ServerError.listenFailed(errno) }
        chmod(path, 0o600) // this socket can make the machine talk
    }

    func run() async {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                log("accept failed: \(errno)")
                break
            }
            // Each connection is handled off the accept loop so a slow reader
            // cannot stall the next client.
            Task { await self.handle(fd) }
        }
    }

    private func handle(_ fd: Int32) async {
        defer { close(fd) }
        guard let line = readLine(fd), !line.isEmpty else { return }

        let resp: Response
        if let data = line.data(using: .utf8),
           let req = try? JSONDecoder().decode(Request.self, from: data) {
            resp = await handler(req)
        } else {
            resp = Response.error("", "malformed request")
        }
        let out = resp.line()
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }

    private func readLine(_ fd: Int32) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if buf.contains(0x0A) { break }
            if buf.count > 1 << 20 { break } // refuse to buffer a firehose
        }
        guard let nl = buf.firstIndex(of: 0x0A) else {
            return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self)
        }
        return String(decoding: buf[0..<nl], as: UTF8.self)
    }

    func shutdown() {
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    enum ServerError: Error, CustomStringConvertible {
        case alreadyRunning
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong(String)

        var description: String {
            switch self {
            case .alreadyRunning: return "another notifyd already owns the socket"
            case .socketFailed(let e): return "socket() failed: \(e)"
            case .bindFailed(let e): return "bind() failed: \(e)"
            case .listenFailed(let e): return "listen() failed: \(e)"
            case .pathTooLong(let p): return "socket path too long for sun_path: \(p)"
            }
        }
    }
}
