import Foundation
import HollerKit
import DotsTTS
import MLX
import Tokenizers

/// One TTS engine. Both engines are fed text that has already been through
/// `TextNormalizer`, so an A/B compares models rather than normalisers.
protocol SpeechEngine: AnyObject, Sendable {
    var kind: EngineKind { get }
    var sampleRate: Double { get }
    func load() async throws
    func isLoaded() async -> Bool
    /// Chunks of mono float32 at `sampleRate`.
    func stream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error>
    /// Per-utterance sampling temperature, or nil to leave the engine default.
    /// Safe despite being engine-global state because `SpeechQueue` serialises
    /// utterances: synthesis of the next one cannot begin until the current one
    /// has finished playing.
    func setTemperature(_ t: Float?)
}

extension SpeechEngine {
    /// Engines without a temperature knob simply ignore it.
    func setTemperature(_ t: Float?) {}
}

// MARK: - Holler

/// Holler 0.6B, a Qwen3-TTS finetune with six curated American voices.
///
/// Defaults here are bf16 + 16 codebooks, the quality end of the model. Note
/// `HollerModel.load()`'s own default repo is the 6-BIT model, so the bf16 repo
/// must be passed explicitly or you silently get the fast variant.
final class HollerEngine: SpeechEngine, @unchecked Sendable {
    let kind: EngineKind = .holler
    let sampleRate: Double = 24_000

    private let repo: String
    private var config: HollerConfiguration
    private var model: HollerModel?
    private let defaultTemperature: Float

    init(repo: String = "sentiuminc/holler-0.6b", codebooks: Int = 16, temperature: Float = 0.7) {
        self.repo = repo
        self.defaultTemperature = temperature
        var c = HollerConfiguration()
        c.codebooks = codebooks
        c.temperature = temperature

        // Disable HollerKit's streaming AGC. Despite the name, `targetLUFS` is
        // not loudness normalization: it is a per-chunk RMS compressor (one
        // chunk = 240 ms) with a ~670 ms one-pole time constant, up to +12 dB
        // of boost, and a 0.9 peak ceiling that writes back into its own gain
        // state so a single loud transient durably pulls the level down and
        // recovers slowly. Audibly, that is pumping plus flattened emphasis.
        //
        // Prosodic loudness contour IS the emotional content of these lines,
        // so a compressor that removes it is removing the feature. We take the
        // raw decoder output and apply one static gain instead (see
        // `Loudness.staticGain`), which cannot pump because it does not adapt.
        c.targetLUFS = nil
        self.config = c
    }

    func load() async throws {
        model = try await HollerModel.load(repo: repo, configuration: config)
    }

    func isLoaded() async -> Bool {
        guard let m = model else { return false }
        return await m.isLoaded
    }

    func voices() async -> [String] {
        guard let m = model else { return [] }
        return await m.voices
    }

    /// Holler's `configuration` is a plain mutable property on a final class and
    /// `stream()` snapshots it at call time, so this takes effect on the very
    /// next utterance and no reload is needed.
    func setTemperature(_ t: Float?) {
        guard let m = model else { return }
        m.configuration.temperature = t ?? defaultTemperature
    }

    func stream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let m = model else { throw NotifydError.engineUnavailable("holler") }
        // HollerKit's silence trimming and retry-on-empty are worth keeping, so
        // we do not re-implement those. Its streaming AGC is switched off in
        // `init` and replaced by the static gain below.
        let inner = m.stream(text, voice: voice)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in inner {
                        continuation.yield(Loudness.applyStatic(chunk.samples))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - dots.tts

/// dots.tts-soar / MeanFlow, 48 kHz continuous AR.
///
/// Clone-only: there is no preset voice, so every call needs a reference clip
/// plus its transcript. We bake that reference from Holler's Oliver
/// (`notifyd --bake-ref`) so both engines speak with the same identity and the
/// A/B isolates fidelity rather than comparing two different people.
///
/// Also note: `generate()` is synchronous, blocking, and non-streaming, so its
/// time-to-first-audio IS its whole-clip generation time.
final class DotsEngine: SpeechEngine, @unchecked Sendable {
    let kind: EngineKind = .dots
    let sampleRate: Double = 48_000

    private let modelRepo: URL
    private let refClip: URL
    private let refTranscriptPath: URL
    private var pipeline: DotsTTSPipeline?
    private var refAudio: MLXArray?
    private var refTranscript: String = ""
    private var params = DotsTTSPipeline.Params()

    /// Serial queue for `generate()`. It blocks for the whole synthesis, so it
    /// must never run on the queue actor's executor or the accept loop stalls.
    private let genQueue = DispatchQueue(label: "dev.notify.dots.generate", qos: .userInitiated)

    init(modelRepo: URL, refClip: URL, refTranscript: URL, numSteps: Int = 4,
         guidance: Float = 1.2, speakerScale: Float = 1.5) {
        self.modelRepo = modelRepo
        self.refClip = refClip
        self.refTranscriptPath = refTranscript
        params.numSteps = numSteps
        params.guidance = guidance
        params.speakerScale = speakerScale
        params.language = "EN" // no auto-detect in this port
    }

    func load() async throws {
        guard FileManager.default.fileExists(atPath: refClip.path) else {
            throw NotifydError.missingReference(refClip.path)
        }
        let tok = try await AutoTokenizer.from(
            modelFolder: modelRepo.appendingPathComponent("backbone"))
        pipeline = try DotsTTSPipeline(modelRepo: modelRepo, tokenizer: tok)

        let samples = try WavIO.readMono(refClip, expectedRate: 48_000)
        refAudio = MLXArray(samples)
        refTranscript = (try? String(contentsOf: refTranscriptPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func isLoaded() async -> Bool { pipeline != nil && refAudio != nil }

    func stream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let pipe = pipeline, let ref = refAudio else {
            throw NotifydError.engineUnavailable("dots")
        }
        let transcript = refTranscript
        let p = params
        let q = genQueue

        return AsyncThrowingStream { continuation in
            q.async {
                let out = pipe.generate(
                    targetText: text, refAudio48k: ref,
                    refTranscript: transcript, params: p)
                eval(out)
                var samples = out.asArray(Float.self) // (1, 1, N) flattens to N
                // dots has no AGC; Holler targets -20 LUFS. Match it or the A/B
                // measures loudness instead of quality.
                Loudness.normalize(&samples, targetLUFS: -20)
                continuation.yield(samples)
                continuation.finish()
            }
        }
    }
}

// MARK: - loudness

enum Loudness {
    /// Fixed output gain for Holler, replacing HollerKit's streaming AGC.
    ///
    /// Calibrated by `notifyd --measure-levels --n 16` against the raw bf16
    /// decoder output: median RMS 0.0751 (-22.5 dBFS), and across everything
    /// from a 0.46 s "no." to a 5 s sentence the whole spread was 0.0534 to
    /// 0.0867. Excluding that one very short line the spread is under 2 dB.
    ///
    /// That measurement is the entire argument for this design: the model's
    /// output is already consistent enough that no dynamics processing is
    /// warranted, so a compressor could only take prosody away. 0.1083 is the
    /// RMS corresponding to a -20 LUFS speech target.
    ///
    /// Worst observed peak was 0.5241, so 1.441x lands at 0.755 and the
    /// headroom to clipping is ~2.4 dB even on the loudest line measured.
    static let hollerStaticGain: Float = 1.441

    /// Static gain plus a soft knee that only engages above 0.95.
    ///
    /// The knee should never fire given the measured headroom; it is here so
    /// that an unusually loud generation degrades into gentle saturation rather
    /// than hard digital clipping. Hard clipping on a plosive is far more
    /// audible than a fraction of a dB of compression on one peak.
    static func applyStatic(_ samples: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        let g = hollerStaticGain
        for i in 0..<samples.count {
            let v = samples[i] * g
            let a = abs(v)
            if a <= 0.95 {
                out[i] = v
            } else {
                // tanh-shaped knee mapping [0.95, inf) into [0.95, 1.0)
                let over = (a - 0.95) / 0.05
                out[i] = (v < 0 ? -1 : 1) * (0.95 + 0.05 * tanh(over))
            }
        }
        return out
    }

    /// Cheap RMS-based approximation of an LUFS target. Not a true K-weighted
    /// meter, but it puts the two engines within a decibel or so of each other,
    /// which is all the A/B needs.
    static func normalize(_ samples: inout [Float], targetLUFS: Float) {
        guard !samples.isEmpty else { return }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 1e-6 else { return }

        let currentDB = 20 * log10(rms)
        // -20 LUFS on speech corresponds to roughly -20 dBFS RMS here.
        var gain = pow(10.0, (Double(targetLUFS) - currentDB) / 20.0)

        // Never let the gain clip the peak.
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        if Double(peak) * gain > 0.99 { gain = 0.99 / Double(peak) }

        let g = Float(gain)
        for i in samples.indices { samples[i] *= g }
    }
}
