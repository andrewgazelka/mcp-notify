import AVFoundation
import Foundation

/// Minimal WAV read/write for the baked reference clip.
enum WavIO {

    /// Read a file as mono float32, resampling if it is not already at
    /// `expectedRate`.
    static func readMono(_ url: URL, expectedRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: expectedRate,
            channels: 1, interleaved: false)
        else { throw NotifydError.badFormat(expectedRate) }

        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames)
        else { return [] }
        try file.read(into: inBuf)

        if src.sampleRate == expectedRate && src.channelCount == 1,
           let ch = inBuf.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: Int(inBuf.frameLength)))
        }

        guard let conv = AVAudioConverter(from: src, to: target) else {
            throw NotifydError.badFormat(expectedRate)
        }
        let ratio = expectedRate / src.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else {
            throw NotifydError.badFormat(expectedRate)
        }

        var done = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Write mono float32 as a 16-bit PCM WAV.
    static func writeMono(_ samples: [Float], to url: URL, sampleRate: Double) throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false)
        else { throw NotifydError.badFormat(sampleRate) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0]
        else { throw NotifydError.badFormat(sampleRate) }
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buf)
    }

    /// Resample mono float32 between rates (used to lift Holler's 24 kHz output
    /// to the 48 kHz dots wants for its reference clip).
    static func resample(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        if from == to { return samples }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                        channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                         channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                           frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = inBuf.floatChannelData?[0]
        else { throw NotifydError.badFormat(to) }

        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        inBuf.frameLength = AVAudioFrameCount(samples.count)

        let outCap = AVAudioFrameCount(Double(samples.count) * to / from) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
            throw NotifydError.badFormat(to)
        }
        var done = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        guard let outCh = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: outCh, count: Int(outBuf.frameLength)))
    }

    /// Trim leading/trailing near-silence.
    static func trimSilence(_ samples: [Float], threshold: Float = 0.01) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold })
        else { return samples }
        return Array(samples[first...last])
    }
}
