import Foundation

/// `~/.local/state/notify/notifyd.json`.
///
/// The CLI reads this instead of probing the socket, so its freshness is what
/// makes the "never wait" invariant cheap: one small read plus `kill(pid, 0)`.
/// Always written via write-to-temp + rename so a reader never sees a torn file.
actor StateFile {
    private let url: URL
    private let socketPath: String

    private var phase: String = "starting"
    private var ready: Bool = false
    private var engines: [String: String] = [:]
    private var download: [String: Any]? = nil

    init(dir: URL, socketPath: String) {
        self.url = dir.appendingPathComponent("notifyd.json")
        self.socketPath = socketPath
    }

    func set(phase: String, ready: Bool? = nil) {
        self.phase = phase
        if let r = ready { self.ready = r }
        write()
    }

    func setEngine(_ name: String, _ status: String) {
        engines[name] = status
        write()
    }

    func setDownload(repo: String?, bytes: UInt64 = 0, total: UInt64 = 0) {
        if let repo {
            download = ["repo": repo, "bytes": bytes, "total": total]
        } else {
            download = nil
        }
        write()
    }

    private func write() {
        var obj: [String: Any] = [
            "v": Proto.version,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "socket": socketPath,
            "ready": ready,
            "phase": phase,
            "engines": engines,
        ]
        if let d = download { obj["download"] = d }
        obj["started_at"] = ISO8601DateFormatter().string(from: Date())

        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("notifyd.json.tmp.\(getpid())")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: tmp)
            // Atomic replace: readers see either the old file or the new one.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Best-effort removal on clean shutdown so the CLI stops trying instantly.
    nonisolated func removeSync(dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("notifyd.json"))
    }
}
