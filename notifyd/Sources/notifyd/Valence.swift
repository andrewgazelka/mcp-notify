import Foundation

/// Valence-keyed prosody shaping.
///
/// Every `notify` line opens with an explicit emotional valence word, by
/// standing convention:
///
///     relieved: the gate passed first try
///     worrying: flat metrics after 8 minutes, investigating now
///     embarrassing: I claimed that file was unchanged and it was not
///
/// That word is a free, perfectly reliable emotion label sitting at the front
/// of every utterance. This layer turns it into delivery.
///
/// WHY THIS EXISTS RATHER THAN AN EXPRESSIVE MODEL: Holler is a finetune of
/// Qwen3-TTS-12Hz-**Base**, and in the released 12 Hz family cloning and
/// instruct-following are disjoint capabilities. Base clones but cannot take
/// emotion instructions; only the 1.7B CustomVoice/VoiceDesign variants
/// instruct, and those cannot clone. So a genuinely expressive engine costs
/// both the Oliver persona and roughly 2-3x the time to first audio. The
/// levers below cost neither: punctuation and sentence shape are things the
/// base model already responds to, and gain and rate are free at playback.
///
/// WHAT THIS DELIBERATELY DOES NOT DO: it never changes a word. It rewrites
/// the separator after the valence word, normalises terminal punctuation, and
/// nudges three continuous parameters. If it ever starts editing prose it has
/// become a different and much worse feature.
struct ValenceProfile: Sendable {
    let family: String
    /// Sampling temperature. Higher widens prosodic variation, but Holler
    /// applies temperature to all 16 RVQ codebooks including the fine acoustic
    /// levels, so past ~0.8 it buys timbral roughness rather than expression.
    /// The whole usable range here is narrow and the values reflect that.
    let temperature: Float
    /// Playback gain in dB, relative to the calibrated static gain. Loudness is
    /// the single most reliable perceptual cue for arousal, and it is exact and
    /// free, unlike anything the model might or might not do with punctuation.
    let gainDB: Float
    /// Multiplier on the configured playback rate. Kept small: the rate is
    /// already 1.5x, and speech intelligibility degrades quickly beyond that.
    let rateScale: Float
    /// Replaces the ":" that follows the valence word.
    let separator: String
    /// Terminal punctuation, applied only if the line has none of its own.
    let terminator: String
}

enum Valence {
    /// Families rather than one entry per word. There are dozens of valence
    /// words in circulation and they cluster into a handful of deliveries;
    /// mapping each word individually would be a table nobody maintains.
    static let families: [String: ValenceProfile] = {
        let bright = ValenceProfile(
            family: "bright", temperature: 0.75, gainDB: 1.0, rateScale: 1.04,
            separator: "!", terminator: "!")
        let settled = ValenceProfile(
            family: "settled", temperature: 0.68, gainDB: 0.3, rateScale: 0.98,
            separator: ",", terminator: ".")
        let tense = ValenceProfile(
            family: "tense", temperature: 0.72, gainDB: 0.5, rateScale: 1.06,
            separator: "...", terminator: ".")
        let flat = ValenceProfile(
            family: "flat", temperature: 0.62, gainDB: -1.0, rateScale: 0.96,
            separator: ".", terminator: ".")
        let sharp = ValenceProfile(
            family: "sharp", temperature: 0.70, gainDB: 1.2, rateScale: 1.02,
            separator: ".", terminator: ".")
        let contrite = ValenceProfile(
            family: "contrite", temperature: 0.66, gainDB: -1.5, rateScale: 0.94,
            separator: "...", terminator: ".")
        let alert = ValenceProfile(
            family: "alert", temperature: 0.74, gainDB: 0.8, rateScale: 1.02,
            separator: ",", terminator: ".")

        var m: [String: ValenceProfile] = [:]
        for w in ["delighted", "delightful", "proud", "satisfying", "satisfied",
                  "excited", "fun", "glad", "pleased", "elegant"] { m[w] = bright }
        for w in ["relieved", "relief", "reassured", "calm", "settled",
                  "confident"] { m[w] = settled }
        for w in ["worrying", "worried", "uneasy", "nervous", "concerning",
                  "concerned", "alarming", "suspicious", "anxious"] { m[w] = tense }
        for w in ["tedious", "boring", "disappointing", "disappointed", "dull",
                  "resigned"] { m[w] = flat }
        for w in ["frustrating", "frustrated", "annoying", "annoyed",
                  "irritating", "irritated", "angry"] { m[w] = sharp }
        for w in ["embarrassing", "embarrassed", "wrong", "sorry", "chastened",
                  "sheepish", "mistaken"] { m[w] = contrite }
        for w in ["surprising", "surprised", "confusing", "confused",
                  "unexpected", "curious", "puzzled", "interesting"] { m[w] = alert }
        return m
    }()

    struct Shaped {
        let text: String
        let profile: ValenceProfile?
    }

    /// Finds the leading valence word and reshapes the line around it.
    ///
    /// The prefix may be a phrase, since lines like "uneasy but glad I checked:"
    /// are normal, so every word before the colon is checked and the first
    /// recognised one wins. A line with no colon, or an unrecognised prefix, is
    /// returned untouched with a nil profile: unknown input must degrade to
    /// exactly today's behaviour, not to a guess.
    static func shape(_ input: String) -> Shaped {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return Shaped(text: text, profile: nil) }

        let prefix = String(text[text.startIndex..<colon])
        // A colon far into the line belongs to the content ("ratio 3:1"), not to
        // a valence prefix.
        guard prefix.count <= 40 else { return Shaped(text: text, profile: nil) }

        let words = prefix.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let profile = words.compactMap({ families[$0] }).first else {
            return Shaped(text: text, profile: nil)
        }

        var body = String(text[text.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        // Terminal punctuation the author wrote is theirs; only supply one if
        // the line ends bare.
        if let last = body.last, ".!?".contains(last) {
            // leave it
        } else if !body.isEmpty {
            body += profile.terminator
        }

        return Shaped(text: prefix + profile.separator + " " + body, profile: profile)
    }

    static func linearGain(db: Float) -> Float { pow(10, db / 20) }
}
