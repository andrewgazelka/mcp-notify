import AVFoundation
import AudioToolbox
import Foundation

/// The playback graph.
///
///   hollerPlayer (24 kHz) -> hollerTimePitch -\
///                                              >- mainMixerNode -> output
///   dotsPlayer   (48 kHz) -> dotsTimePitch   -/
///
/// One chain per source sample rate, rather than one shared chain with manual
/// resampling: AVAudioEngine inserts implicit sample-rate converters at MIXER
/// inputs, not at effect-node connections, so giving each source its native
/// format and letting the mixer do the conversion is the sanctioned path.
///
/// `AVAudioUnitTimePitch` gives the speed-up WITHOUT the chipmunk pitch shift
/// that `afplay -r` would produce.
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var chains: [Double: (player: AVAudioPlayerNode, pitch: AVAudioUnitTimePitch)] = [:]
    private let lock = NSLock()
    private var started = false

    /// Set by `--bench`: records when the first audible sample hit the mixer.
    private var ttfaTap: (@Sendable (Double) -> Void)?
    private var ttfaArmed = false
    private var ttfaOrigin: UInt64 = 0

    init() {
        for sr in [24_000.0, 48_000.0] { makeChain(sampleRate: sr) }
    }

    private func makeChain(sampleRate: Double) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false)
        else { return }

        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = 0 // cents; always zero, we only ever change rate

        // Quality knobs on AUNewTimePitch. Time-stretching speech to 1.5x is the
        // single most artifact-prone step in this pipeline, so it gets the
        // expensive settings: this is one mono voice stream on an M-series GPU
        // box, the CPU cost is noise.
        //
        // `overlap` is the deprecated alias for kNewTimePitchParam_Smoothness,
        // range 3...32, default 8. The header is explicit that higher means
        // fewer artifacts at directly proportional CPU cost. We take the max.
        pitch.overlap = 32.0

        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: fmt)
        engine.connect(pitch, to: engine.mainMixerNode, format: fmt)

        // Two more AUNewTimePitch parameters that AVAudioUnitTimePitch does not
        // surface as Swift properties, reachable only through the raw AudioUnit:
        //
        //   EnableSpectralCoherence (peak locking) - kills the "phasey",
        //     reverberant smearing a plain phase vocoder gives a human voice.
        //   EnableTransientPreservation - resets phase at transients and
        //     locally sets the stretch factor to 1, which is what keeps plosives
        //     and fricatives crisp instead of smeared at 1.5x.
        //
        // Both document a default of 1, but "documented default" and "what this
        // unit actually reports" are different claims, so set them explicitly
        // and verify. A failure here is a quality regression, not a crash, which
        // is exactly the kind that ships silently.
        setAUParam(pitch, kNewTimePitchParam_EnableSpectralCoherence, 1, "spectral coherence")
        setAUParam(pitch, kNewTimePitchParam_EnableTransientPreservation, 1, "transient preservation")

        chains[sampleRate] = (player, pitch)
    }

    private func setAUParam(
        _ unit: AVAudioUnitTimePitch, _ id: AudioUnitParameterID,
        _ value: AudioUnitParameterValue, _ label: String
    ) {
        let st = AudioUnitSetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, value, 0)
        if st != noErr { FileHandle.standardError.write(Data("notifyd: could not set \(label) (OSStatus \(st))\n".utf8)) }
    }

    /// Reports the quality parameters actually in effect, so `--selftest-audio`
    /// can prove them rather than assume them.
    func qualityReport() -> String {
        var out: [String] = []
        for sr in chains.keys.sorted() {
            guard let pitch = chains[sr]?.pitch else { continue }
            var coherence: AudioUnitParameterValue = -1
            var transient: AudioUnitParameterValue = -1
            AudioUnitGetParameter(pitch.audioUnit, kNewTimePitchParam_EnableSpectralCoherence,
                                  kAudioUnitScope_Global, 0, &coherence)
            AudioUnitGetParameter(pitch.audioUnit, kNewTimePitchParam_EnableTransientPreservation,
                                  kAudioUnitScope_Global, 0, &transient)
            out.append(String(
                format: "  %.0f Hz chain  smoothness %.1f/32  spectral-coherence %.0f  transient-preservation %.0f",
                sr, pitch.overlap, coherence, transient))
        }
        let mixFmt = engine.mainMixerNode.outputFormat(forBus: 0)
        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        out.append(String(format: "  mixer out %.0f Hz %u ch   device out %.0f Hz %u ch",
                          mixFmt.sampleRate, mixFmt.channelCount,
                          outFmt.sampleRate, outFmt.channelCount))
        out.append("  resampler   AVAudioConverter, quality max, mastering algorithm")
        out.append("  mixer SRC   bypassed (sources are converted to device rate first)")
        return out.joined(separator: "\n")
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }

        engine.prepare()
        try engine.start()
        started = true
    }

    /// Let the audio device sleep when nothing is speaking.
    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        engine.pause()
        started = false
    }

    /// Arm a one-shot time-to-first-audible-speech measurement.
    ///
    /// Measured at the MIXER, not at the first scheduled buffer, so the number
    /// includes the graph and the audio HAL - which is what "you never wait"
    /// is actually judged on.
    func armTTFA(origin: UInt64, _ cb: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        ttfaOrigin = origin
        ttfaTap = cb
        ttfaArmed = true
        let mixer = engine.mainMixerNode
        lock.unlock()

        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.lock()
            guard self.ttfaArmed, let cb = self.ttfaTap else { self.lock.unlock(); return }
            let origin = self.ttfaOrigin
            self.lock.unlock()

            guard let ch = buf.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
            // Threshold, not >0: the codec decoder emits near-silence first and
            // we want the moment speech is audible.
            guard peak > 0.01 else { return }

            self.lock.lock()
            self.ttfaArmed = false
            self.lock.unlock()
            cb(Self.msSince(origin))
            mixer.removeTap(onBus: 0)
        }
    }

    /// The hardware output rate. Anything else has to be converted somewhere,
    /// and we would rather it be somewhere we control.
    func deviceRate() -> Double {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return sr > 0 ? sr : 48_000
    }

    static func now() -> UInt64 { mach_absolute_time() }

    static func msSince(_ origin: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let delta = mach_absolute_time() - origin
        return Double(delta) * Double(info.numer) / Double(info.denom) / 1_000_000.0
    }

    private func buffer(_ samples: [Float], _ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(
                pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { src in
            ch.update(from: src.baseAddress!, count: samples.count)
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        return buf
    }

    /// Play a sequence of chunks, returning once the last sample has been heard.
    ///
    /// `onFirstBuffer` fires just before the node is started, which is where the
    /// caller takes the cross-process utterance lock.
    func play(
        chunks: AsyncThrowingStream<[Float], Error>,
        sampleRate: Double,
        rate: Float,
        gain: Float = 1.0,
        onFirstBuffer: (() -> Void)? = nil
    ) async throws {
        try start()

        // Play at the DEVICE rate, converting here rather than letting the
        // mixer do it. AVAudioMixerNode's implicit input converter has no
        // exposed quality setting (its node is not an AVAudioIONode, so the
        // underlying AudioUnit and kAudioUnitProperty_RenderQuality are simply
        // not reachable), and it sits on the critical path of every 24 kHz
        // Holler utterance. An explicit AVAudioConverter can be pinned to
        // mastering quality and, as a bonus, means the time-stretch runs at
        // full device bandwidth instead of being resampled after the fact.
        let target = deviceRate()
        let playRate = chains[target] != nil ? target : sampleRate
        guard let chain = chains[playRate],
              let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: playRate,
                channels: 1, interleaved: false)
        else { throw NotifydError.badFormat(sampleRate) }

        // One converter for the whole utterance, never one per chunk: the
        // converter carries filter state across calls, and rebuilding it per
        // chunk would put a discontinuity at every chunk boundary. Holler
        // streams a chunk every 3 tokens, so that would be a click every 250 ms.
        let resampler = playRate == sampleRate
            ? nil
            : try StreamResampler(from: sampleRate, to: playRate)

        chain.pitch.rate = min(max(rate, 0.5), 3.0)

        let tracker = PlaybackTracker()
        var didStart = false

        for try await raw in chunks {
            var samples = try resampler.map { try $0.convert(raw) } ?? raw
            // Valence gain. Applied here rather than in the engine so it is a
            // playback property: it stays out of the synthesis path and cannot
            // affect what the model generates.
            if gain != 1.0 { for i in 0..<samples.count { samples[i] *= gain } }
            guard let buf = buffer(samples, fmt) else { continue }
            await tracker.willSchedule()
            chain.player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
                Task { await tracker.didPlay() }
            }
            if !didStart {
                onFirstBuffer?()
                chain.player.play()
                didStart = true
            }
        }

        if !didStart { return } // nothing was generated
        await tracker.finishScheduling()
        await tracker.waitUntilDrained()
    }

    func stopAll() {
        for (_, c) in chains { c.player.stop() }
    }
}

/// Counts scheduled vs played-back buffers so `play` can await true completion
/// rather than guessing from the stream ending.
private actor PlaybackTracker {
    private var scheduled = 0
    private var played = 0
    private var schedulingDone = false
    private var waiter: CheckedContinuation<Void, Never>?

    func willSchedule() { scheduled += 1 }

    func didPlay() {
        played += 1
        maybeResume()
    }

    func finishScheduling() {
        schedulingDone = true
        maybeResume()
    }

    func waitUntilDrained() async {
        if schedulingDone && played >= scheduled { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiter = c
            maybeResume()
        }
    }

    private func maybeResume() {
        guard schedulingDone, played >= scheduled, let w = waiter else { return }
        waiter = nil
        w.resume()
    }
}

enum NotifydError: Error, CustomStringConvertible {
    case badFormat(Double)
    case engineUnavailable(String)
    case missingReference(String)

    var description: String {
        switch self {
        case .badFormat(let sr): return "unsupported sample rate \(sr)"
        case .engineUnavailable(let e): return "engine \(e) unavailable"
        case .missingReference(let p): return "missing dots reference clip at \(p)"
        }
    }
}


/// A sample-rate converter that stays alive for a whole utterance.
///
/// Pinned to the mastering algorithm at max quality. For the 24 kHz -> 48 kHz
/// case this is an exact 2x ratio and any converter would do a decent job, but
/// the device rate is whatever the user's output device says it is, and 24 ->
/// 44.1 kHz is a genuinely hard ratio where converter quality is audible.
final class StreamResampler {
    private let converter: AVAudioConverter
    private let inFmt: AVAudioFormat
    private let outFmt: AVAudioFormat
    private let ratio: Double

    init(from: Double, to: Double) throws {
        guard let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                    channels: 1, interleaved: false),
              let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                    channels: 1, interleaved: false),
              let c = AVAudioConverter(from: i, to: o)
        else { throw NotifydError.badFormat(to) }
        c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        (converter, inFmt, outFmt, ratio) = (c, i, o, to / from)
    }

    func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                           frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = inBuf.floatChannelData?[0]
        else { return [] }
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        inBuf.frameLength = AVAudioFrameCount(samples.count)

        let cap = AVAudioFrameCount(Double(samples.count) * ratio) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        // .inputRanDry is the normal terminal state when streaming chunk by
        // chunk: it means "I consumed everything you gave me", not an error.
        if status == .error, let err { throw err }
        guard let outCh = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: outCh, count: Int(outBuf.frameLength)))
    }
}
