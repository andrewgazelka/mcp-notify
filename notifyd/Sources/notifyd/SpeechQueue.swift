import Foundation

/// The serialization point for all speech.
///
/// Being an actor with a single in-flight task is what makes overlap
/// structurally impossible: there is one `await` chain, so two utterances
/// cannot be playing at once regardless of how many clients connect.
actor SpeechQueue {
    struct Item {
        let id: String
        let text: String
        let engine: EngineKind
        let voice: String
        let rate: Float
        let priority: Priority
        let enqueued: Date
        let staleAfterMs: Int
    }

    private var pending: [Item] = []
    private var running = false
    private var currentTask: Task<Void, Never>?

    private let player: AudioPlayer
    private let engines: EngineRegistry
    private let log: @Sendable (String) -> Void

    /// Recently spoken text, for dedupe.
    private var recent: [(text: String, at: Date)] = []

    // Backpressure thresholds. A runaway agent loop must not be able to queue
    // a minute of speech.
    private let dropLowAbove = 4
    private let dropNormalAbove = 8
    private let dedupeWindow: TimeInterval = 2.0

    /// Valence-keyed prosody shaping. On by default; `NOTIFY_PROSODY=0` or
    /// `notifyd --no-prosody` turns it off, which exists so the two can be
    /// compared by ear rather than argued about.
    private let prosody: Bool

    init(player: AudioPlayer, engines: EngineRegistry,
         prosody: Bool = true,
         log: @escaping @Sendable (String) -> Void) {
        self.player = player
        self.engines = engines
        self.prosody = prosody
        self.log = log
    }

    var depth: Int { pending.count }

    enum Admission {
        case queued(depth: Int)
        case dropped(reason: String)
    }

    func submit(_ item: Item, interrupt: Bool) -> Admission {
        // 1. Dedupe: the same line twice in two seconds is a loop, not emphasis.
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.at) > dedupeWindow }
        if recent.contains(where: { $0.text == item.text })
            || pending.contains(where: { $0.text == item.text }) {
            return .dropped(reason: "duplicate")
        }

        if interrupt {
            currentTask?.cancel()
            player.stopAll()
            pending.removeAll { $0.priority == .low }
        }

        switch item.priority {
        case .high:
            // Jumps the queue but does NOT cut off the current utterance:
            // truncating mid-word is worse than a two second wait.
            pending.insert(item, at: 0)
        case .normal, .low:
            pending.append(item)
        }

        // 2. Backpressure.
        if pending.count > dropNormalAbove {
            if let i = pending.firstIndex(where: { $0.priority != .high }) {
                let dropped = pending.remove(at: i)
                log("backpressure: dropped \(dropped.id) (depth \(pending.count))")
            }
        } else if pending.count > dropLowAbove {
            if let i = pending.firstIndex(where: { $0.priority == .low }) {
                pending.remove(at: i)
            }
        }

        recent.append((item.text, now))
        let d = pending.count
        pump()
        return .queued(depth: d)
    }

    private func pump() {
        guard !running, !pending.isEmpty else { return }
        running = true
        currentTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()

            // 3. Staleness: a warning delivered 45s late is noise, not signal.
            let ageMs = Date().timeIntervalSince(item.enqueued) * 1000
            if ageMs > Double(item.staleAfterMs) {
                log("stale: dropped \(item.id) after \(Int(ageMs))ms")
                continue
            }
            if Task.isCancelled { break }

            do {
                try await speak(item)
            } catch {
                log("speak failed for \(item.id): \(error)")
            }
        }
        running = false
        if !pending.isEmpty { pump() }
    }

    private func speak(_ item: Item) async throws {
        guard let engine = await engines.engine(item.engine) else {
            throw NotifydError.engineUnavailable(item.engine.rawValue)
        }
        // Valence-keyed prosody. The leading emotion word is a free, exact
        // label; this turns it into delivery instead of leaving it purely
        // lexical. Unrecognised or colon-less lines come back untouched with a
        // nil profile and behave exactly as before.
        let shaped = prosody ? Valence.shape(item.text) : Valence.Shaped(text: item.text, profile: nil)
        engine.setTemperature(shaped.profile?.temperature)
        let gain = shaped.profile.map { Valence.linearGain(db: $0.gainDB) } ?? 1.0
        let rate = item.rate * (shaped.profile?.rateScale ?? 1.0)

        let chunks = try await engine.stream(text: shaped.text, voice: item.voice)

        // The cross-process lock is taken around PLAYBACK ONLY, immediately
        // before the node starts, and released when the last buffer has been
        // heard. Held any earlier it would block a `say` fallback during our
        // synthesis for no reason.
        let lock = UtteranceLock()
        defer { lock.release() }

        try await player.play(
            chunks: chunks,
            sampleRate: engine.sampleRate,
            rate: rate,
            gain: gain,
            onFirstBuffer: { lock.acquire() }
        )
    }
}

/// Holds the engines and loads them lazily.
///
/// `dots` is deliberately NOT loaded at warm-up: it would double cold-start
/// cost for an engine that may never be asked for in a given session.
actor EngineRegistry {
    private var loaded: [EngineKind: SpeechEngine] = [:]
    private var loading: Set<EngineKind> = []
    private let make: @Sendable (EngineKind) -> SpeechEngine?
    private let onStatus: @Sendable (String, String) -> Void

    init(make: @escaping @Sendable (EngineKind) -> SpeechEngine?,
         onStatus: @escaping @Sendable (String, String) -> Void) {
        self.make = make
        self.onStatus = onStatus
    }

    func engine(_ kind: EngineKind) -> SpeechEngine? { loaded[kind] }

    func isLoaded(_ kind: EngineKind) -> Bool { loaded[kind] != nil }

    /// Load if needed. Returns true once the engine is usable.
    @discardableResult
    func ensure(_ kind: EngineKind) async -> Bool {
        if loaded[kind] != nil { return true }
        if loading.contains(kind) { return false }
        guard let e = make(kind) else {
            onStatus(kind.rawValue, "unavailable")
            return false
        }
        loading.insert(kind)
        onStatus(kind.rawValue, "loading")
        do {
            try await e.load()
            loaded[kind] = e
            loading.remove(kind)
            onStatus(kind.rawValue, "loaded")
            return true
        } catch {
            loading.remove(kind)
            onStatus(kind.rawValue, "error: \(error)")
            return false
        }
    }

    /// Kick off a load without waiting for it.
    func warm(_ kind: EngineKind) {
        Task { await self.ensure(kind) }
    }
}
