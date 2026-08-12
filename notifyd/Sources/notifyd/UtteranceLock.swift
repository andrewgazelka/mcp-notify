import Foundation

/// `flock(LOCK_EX)` on `~/.notify-lock/say.lock`.
///
/// This is the SAME file the Rust CLI's `say` fallback takes. That shared lock
/// is the only thing preventing a fallback utterance from talking over the
/// daemon during warm-up or right after a crash, and it is why the path is
/// hard-coded on both sides.
///
/// Held around PLAYBACK only, never around synthesis: the daemon should be free
/// to generate the next utterance while a `say` child finishes speaking.
final class UtteranceLock {
    private var fd: Int32 = -1

    static func path() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(".notify-lock")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("say.lock")
    }

    func acquire() {
        let p = Self.path()
        fd = open(p, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        // Blocking: we genuinely want to wait our turn rather than overlap.
        _ = flock(fd, LOCK_EX)
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
