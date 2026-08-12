import AVFoundation
import Foundation
import MLX

// notifyd - resident neural voice for `notify`.
//
// Modes:
//   --serve            run the daemon (what launchd starts)
//   --selftest-metal   prove the Metal shaders are linked in THIS build
//   --bake-ref         generate the shared Oliver reference clip for dots
//   --bench            measure TTFA at the speaker
//   --say              one-shot synth+play, for manual A/B

// MARK: - paths & config

struct Paths {
    static var home: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    }
    static var stateDir: URL {
        if let s = ProcessInfo.processInfo.environment["NOTIFY_STATE_DIR"], !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        return home.appendingPathComponent(".local/state/notify")
    }
    static var socket: String {
        if let s = ProcessInfo.processInfo.environment["NOTIFY_SOCKET"], !s.isEmpty { return s }
        return stateDir.appendingPathComponent("notifyd.sock").path
    }
    static var cacheDir: URL { home.appendingPathComponent(".cache/notify") }
    static var refClip: URL { cacheDir.appendingPathComponent("voices/oliver-ref-48k.wav") }
    static var refText: URL { cacheDir.appendingPathComponent("voices/oliver-ref.txt") }

    /// dots weights: the `mf` subdirectory is the MeanFlow (NFE=4) checkpoint
    /// and is self-contained.
    static var dotsRepo: URL? {
        if let s = ProcessInfo.processInfo.environment["NOTIFY_DOTS_REPO"], !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        let hub = home.appendingPathComponent(
            ".cache/huggingface/hub/models--smcleod--dots.tts-soar-mlx/snapshots")
        guard let snaps = try? FileManager.default.contentsOfDirectory(
            at: hub, includingPropertiesForKeys: nil), let first = snaps.first
        else { return nil }
        return first.appendingPathComponent("mf")
    }
}

func logLine(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(s)\n".utf8))
}

func makeEngine(_ kind: EngineKind) -> SpeechEngine? {
    switch kind {
    case .holler:
        let repo = ProcessInfo.processInfo.environment["NOTIFY_HOLLER_REPO"]
            ?? "sentiuminc/holler-0.6b"
        return HollerEngine(repo: repo)
    case .dots:
        guard let repo = Paths.dotsRepo else { return nil }
        return DotsEngine(modelRepo: repo, refClip: Paths.refClip, refTranscript: Paths.refText)
    }
}

// MARK: - modes

/// Prints what the playback graph is ACTUALLY configured at. The TimePitch
/// quality parameters have documented defaults, but a documented default is a
/// claim about the SDK, not a measurement of this process, and a silently
/// unapplied parameter degrades every utterance without ever failing.
/// Measures the RAW decoder output level across a spread of utterances, with
/// the streaming AGC disabled. This exists so the replacement static gain is
/// calibrated against this model's actual output distribution rather than
/// picked to look reasonable.
func measureLevels(voice: String, n: Int) async -> Int32 {
    let lines = [
        "relieved: the gate passed first try",
        "worrying: flat metrics after eight minutes, investigating now",
        "delighted: seventeen times faster, and the bench confirms it",
        "embarrassing: I claimed that file was unchanged and it was not",
        "the build finished cleanly and every test passed on the first run",
        "no.",
        "tedious: forty one directories, fourteen levels, one request each",
        "proud: three hundred milliseconds to first audio, measured at the speaker",
    ]
    let engine = HollerEngine()
    do { try await engine.load() } catch {
        print("levels: load failed - \(error)")
        return 1
    }

    var rmsAll: [Float] = []
    var peakAll: [Float] = []
    for i in 0..<n {
        let text = lines[i % lines.count]
        do {
            var samples: [Float] = []
            for try await c in try await engine.stream(text: text, voice: voice) { samples += c }
            guard !samples.isEmpty else { continue }
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            let peak = samples.map { abs($0) }.max() ?? 0
            rmsAll.append(rms); peakAll.append(peak)
            print(String(format: "  %2d  rms %.4f (%.1f dBFS)  peak %.4f (%.1f dBFS)  %.2fs  %@",
                         i, rms, 20 * log10(max(rms, 1e-9)), peak, 20 * log10(max(peak, 1e-9)),
                         Double(samples.count) / 24000.0, text))
        } catch { print("  \(i)  error \(error)") }
    }
    guard !rmsAll.isEmpty else { return 1 }
    let med = { (a: [Float]) -> Float in a.sorted()[a.count / 2] }
    let medRMS = med(rmsAll), maxPeak = peakAll.max() ?? 0
    // -20 LUFS is roughly 0.1083 RMS for this kind of material; that is the
    // level Siri and podcast masters sit at, so it is the right target to keep.
    let target: Float = 0.1083
    let gain = target / medRMS
    print(String(format: "\nmedian rms %.4f (%.1f dBFS)   max peak %.4f   rms spread %.4f..%.4f",
                 medRMS, 20 * log10(medRMS), maxPeak, rmsAll.min()!, rmsAll.max()!))
    print(String(format: "static gain for -20 LUFS target: %.3f  (worst-case peak after gain %.3f)",
                 gain, maxPeak * gain))
    return 0
}

func selftestAudio() -> Int32 {
    let player = AudioPlayer()
    do { try player.start() } catch {
        print("audio: engine failed to start - \(error)")
        return 1
    }
    print("audio graph quality:")
    print(player.qualityReport())
    player.pause()
    return 0
}

func selftestMetal() -> Int32 {
    let a = MLXArray([1.0, 2.0, 3.0] as [Float])
    let b = a * 2.0 + 1.0
    eval(b)
    let got = b.asArray(Float.self)
    guard got == [3.0, 5.0, 7.0] else {
        print("metal selftest FAILED: \(got)")
        return 1
    }
    print("metal ok  device=\(Device.defaultDevice())  result=\(got)")
    return 0
}

/// Bake the shared reference clip: Holler's Oliver at 48 kHz plus its exact
/// transcript, so dots clones the same identity and the A/B isolates the model.
///
/// Length is deliberate: dots crops speaker conditioning at 10s and Holler's
/// own notes favour 7-11s references.
func bakeReference() async -> Int32 {
    let text = """
    The build finished in twelve seconds, down from three minutes. \
    Every gate passed on the first attempt. \
    I checked the artifact directly rather than trusting the report, \
    and the numbers hold up.
    """
    let normalized = TextNormalizer.normalize(text)

    logLine("baking reference from Holler/oliver")
    let holler = HollerEngine()
    do {
        try await holler.load()
        var all: [Float] = []
        for try await chunk in try await holler.stream(text: normalized, voice: "oliver") {
            all.append(contentsOf: chunk)
        }
        guard !all.isEmpty else { logLine("bake produced no audio"); return 1 }

        all = WavIO.trimSilence(all)
        var up = try WavIO.resample(all, from: 24_000, to: 48_000)
        // -22 LUFS: Holler's stated training target for reference material.
        Loudness.normalize(&up, targetLUFS: -22)

        try FileManager.default.createDirectory(
            at: Paths.refClip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WavIO.writeMono(up, to: Paths.refClip, sampleRate: 48_000)
        // The transcript must match the spoken text EXACTLY or cloning degrades.
        try normalized.write(to: Paths.refText, atomically: true, encoding: .utf8)

        let secs = Double(up.count) / 48_000
        logLine(String(format: "reference written: %.2fs -> %@", secs, Paths.refClip.path))
        if secs < 6 || secs > 12 {
            logLine("WARNING: reference is \(String(format: "%.1f", secs))s; 8-10s is the sweet spot")
        }
        return 0
    } catch {
        logLine("bake failed: \(error)")
        return 1
    }
}

/// One-shot: synthesize and play. Used by the A/B harness.
func sayOnce(text: String, engineKind: EngineKind, voice: String, rate: Float) async -> Int32 {
    guard let engine = makeEngine(engineKind) else {
        logLine("engine \(engineKind.rawValue) unavailable"); return 1
    }
    let player = AudioPlayer()
    do {
        try await engine.load()
        let normalized = TextNormalizer.normalize(text)
        let origin = AudioPlayer.now()
        player.armTTFA(origin: origin) { ms in
            logLine(String(format: "TTFA %.1f ms (%@)", ms, engineKind.rawValue))
        }
        let chunks = try await engine.stream(text: normalized, voice: voice)
        let lock = UtteranceLock()
        defer { lock.release() }
        try await player.play(chunks: chunks, sampleRate: engine.sampleRate,
                              rate: rate, onFirstBuffer: { lock.acquire() })
        return 0
    } catch {
        logLine("say failed: \(error)")
        return 1
    }
}

/// Measure time to first AUDIBLE speech at the mixer, including the audio HAL.
func bench(engineKind: EngineKind, voice: String, rate: Float, n: Int) async -> Int32 {
    let sentences = [
        "The gate passed on the first try.",
        "Flat metrics after eight minutes; that is worrying.",
        "Seventeen seconds, down from eight hundred and twenty.",
        "I checked the artifact rather than the report.",
        "The reference clip is baked and cached.",
        "Both engines are resident and warm.",
    ]
    guard let engine = makeEngine(engineKind) else {
        logLine("engine \(engineKind.rawValue) unavailable"); return 1
    }
    let player = AudioPlayer()
    do {
        let t0 = AudioPlayer.now()
        try await engine.load()
        logLine(String(format: "load: %.0f ms", AudioPlayer.msSince(t0)))
    } catch {
        logLine("load failed: \(error)"); return 1
    }

    var ttfas: [Double] = []
    var rtfs: [Double] = []

    for i in 0..<n {
        let text = TextNormalizer.normalize(sentences[i % sentences.count])
        let origin = AudioPlayer.now()
        let box = TTFABox()
        player.armTTFA(origin: origin) { ms in box.set(ms) }
        do {
            let chunks = try await engine.stream(text: text, voice: voice)
            let counter = SampleCounter()
            let counting = AsyncThrowingStream<[Float], Error> { c in
                Task {
                    do {
                        for try await s in chunks { counter.add(s.count); c.yield(s) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
            }
            try await player.play(chunks: counting, sampleRate: engine.sampleRate, rate: rate)
            let wall = AudioPlayer.msSince(origin) / 1000.0
            let audioSecs = Double(counter.get()) / engine.sampleRate / Double(rate)
            if audioSecs > 0 { rtfs.append(wall / audioSecs) }
            if let t = box.get() { ttfas.append(t) }
        } catch {
            logLine("iteration \(i) failed: \(error)")
        }
    }

    func pct(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        return s[min(Int(Double(s.count) * q), s.count - 1)]
    }
    let label = engineKind == .dots
        ? "TTFA (== whole-clip generation; dots does not stream)"
        : "TTFA (to first audible speech)"
    print("engine     \(engineKind.rawValue)  rate \(rate)  n=\(ttfas.count)")
    print(String(format: "%@  median %.1f ms  p95 %.1f ms", label, pct(ttfas, 0.5), pct(ttfas, 0.95)))
    print(String(format: "RTF (incl. playback wait)  median %.2f", pct(rtfs, 0.5)))
    return 0
}

/// Counts samples across the streaming Task boundary. A plain `var` captured in
/// a Task is a Swift 6 data race; this is the smallest safe equivalent.
final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Small box so the tap callback can hand a value back across the concurrency
/// boundary without capturing a mutable local.
final class TTFABox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    func get() -> Double? { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - serve

func serve(preload: [EngineKind]) async -> Int32 {
    let socketPath = Paths.socket
    let state = StateFile(dir: Paths.stateDir, socketPath: socketPath)
    await state.set(phase: "starting", ready: false)

    let player = AudioPlayer()
    let registry = EngineRegistry(make: makeEngine) { name, status in
        Task { await state.setEngine(name, status) }
    }
    let queue = SpeechQueue(player: player, engines: registry, log: logLine)

    let server = SocketServer(path: socketPath, log: logLine) { req in
        switch req.op {
        case "status":
            return Response(id: req.id, status: "ok",
                            queue_depth: await queue.depth, ready: true)
        case "warm":
            if let k = EngineKind(req.engine) { await registry.warm(k) }
            return Response(id: req.id, status: "ok")
        case "stop":
            player.stopAll()
            return Response(id: req.id, status: "ok")
        case "speak":
            guard let kind = EngineKind(req.engine) else {
                return Response.error(req.id, "unknown engine \(req.engine)")
            }
            guard await registry.isLoaded(kind) else {
                // Kick off the load so the NEXT call lands neural, and tell the
                // CLI to use `say` right now rather than making it wait.
                await registry.warm(kind)
                return Response.notReady(req.id, "engine_cold")
            }
            let item = SpeechQueue.Item(
                id: req.id, text: TextNormalizer.normalize(req.text),
                engine: kind, voice: req.voice, rate: req.rate,
                priority: Priority(req.priority), enqueued: Date(),
                staleAfterMs: req.stale_after_ms)
            switch await queue.submit(item, interrupt: req.interrupt) {
            case .queued(let d): return Response.queued(req.id, depth: d, engine: kind.rawValue)
            case .dropped(let r): return Response.dropped(req.id, r)
            }
        default:
            return Response.error(req.id, "unknown op \(req.op)")
        }
    }

    do {
        try server.bindAndListen()
    } catch SocketServer.ServerError.alreadyRunning {
        // Another instance owns the socket. Exiting cleanly is correct: launchd
        // sees a successful exit and leaves us alone.
        logLine("another notifyd is already serving; exiting")
        return 0
    } catch {
        logLine("bind failed: \(error)")
        return 1
    }

    // Signal handling, and the queue choice here is load-bearing.
    //
    // `signal(sig, SIG_IGN)` is required before a DispatchSource signal source
    // (otherwise the default action kills us before the source ever sees it),
    // but it means that if the source never fires, the signal is now fully
    // IGNORED rather than merely unhandled. Putting the source on `.main` did
    // exactly that: under Swift's async main the main dispatch queue is never
    // serviced, so the handler could not run and notifyd became immune to
    // SIGTERM, killable only with SIGKILL.
    //
    // That is not a cosmetic bug. launchd stops and restarts agents with
    // SIGTERM, so an unkillable daemon means `launchctl kickstart -k` leaves
    // the OLD binary running and every reinstall silently accumulates another
    // orphan competing for the socket. Verified: three orphans after three
    // installs. The source must live on a queue that is actually running.
    let signalQueue = DispatchQueue(label: "dev.notify.signals")
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        src.setEventHandler {
            logLine("caught signal \(sig), shutting down")
            server.shutdown()
            try? FileManager.default.removeItem(
                at: Paths.stateDir.appendingPathComponent("notifyd.json"))
            exit(0)
        }
        src.resume()
        // Sources are cancelled on deallocation, so they have to outlive this
        // loop's scope or the handler is torn down the moment we leave it.
        signalSources.append(src)
    }
    defer { signalSources.forEach { $0.cancel() } }

    await state.set(phase: "loading", ready: false)
    for kind in preload {
        let ok = await registry.ensure(kind)
        logLine("preload \(kind.rawValue): \(ok ? "loaded" : "failed")")
    }
    try? player.start()
    await state.set(phase: "serving", ready: true)
    logLine("serving on \(socketPath)")

    await server.run()
    return 0
}

// MARK: - entry

func run() async -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    func flag(_ n: String) -> Bool {
        if let i = args.firstIndex(of: n) { args.remove(at: i); return true }
        return false
    }
    func value(_ n: String) -> String? {
        guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    let doSelftest = flag("--selftest-metal")
    let doSelftestAudio = flag("--selftest-audio")
    let doLevels = flag("--measure-levels")
    let doBake = flag("--bake-ref")
    let doBench = flag("--bench")
    let doSay = flag("--say")
    let doServe = flag("--serve")

    let engineKind = EngineKind(value("--engine") ?? "holler") ?? .holler
    let voice = value("--voice") ?? "oliver"
    let rate = Float(value("--rate") ?? "1.5") ?? 1.5
    let n = Int(value("--n") ?? "20") ?? 20
    let text = value("--text") ?? args.first(where: { !$0.hasPrefix("--") }) ?? "Hello."

    if doSelftest { return selftestMetal() }
    if doSelftestAudio { return selftestAudio() }
    if doLevels { return await measureLevels(voice: voice, n: n) }
    if doBake { return await bakeReference() }
    if doBench { return await bench(engineKind: engineKind, voice: voice, rate: rate, n: n) }
    if doSay { return await sayOnce(text: text, engineKind: engineKind, voice: voice, rate: rate) }
    if doServe { return await serve(preload: [.holler]) }

    print("""
    notifyd - resident neural voice for notify

      --serve                      run the daemon (launchd entry point)
      --selftest-metal             verify Metal shaders are linked
      --selftest-audio             report the audio quality parameters in effect
      --measure-levels             raw output level distribution (AGC calibration)
      --bake-ref                   generate the shared Oliver reference clip
      --bench [--engine E] [--n N] measure TTFA at the speaker
      --say --text T [--engine E]  one-shot synthesize and play

    options: --engine holler|dots  --voice NAME  --rate FLOAT
    """)
    return 0
}

exit(await run())
