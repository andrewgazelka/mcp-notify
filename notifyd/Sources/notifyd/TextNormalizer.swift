import Foundation

/// Turns terse status prose into something a TTS model pronounces correctly.
///
/// Applied to BOTH engines, deliberately. dots.tts ships no text normalisation
/// at all and Holler's is minimal; if only one engine got this, an A/B would be
/// comparing normalisers rather than voices.
///
/// Tuned for the vocabulary this tool actually speaks: durations, percentages,
/// speedups, percentile labels, byte sizes.
enum TextNormalizer {

    static func normalize(_ input: String) -> String {
        var s = input

        // Percentile labels before generic number handling: p99 -> "p ninety nine"
        // reads badly; "99th percentile" is what a person would say.
        s = regex(s, #"\bp(50|75|90|95|99|999)\b"#) { m in
            let n = m[1]
            if n == "999" { return "99.9th percentile" }
            return "\(ordinal(Int(n)!)) percentile"
        }

        // Speedups: "17x", "2.5x" -> "17 times", "2.5 times"
        s = regex(s, #"(\d+(?:\.\d+)?)x\b"#) { m in "\(m[1]) times" }

        // Byte sizes: 2.3GB -> "2.3 gigabytes"
        s = regex(s, #"(\d+(?:\.\d+)?)\s?(TB|GB|MB|KB|kB)\b"#) { m in
            let unit: String
            switch m[2].lowercased() {
            case "tb": unit = "terabyte"
            case "gb": unit = "gigabyte"
            case "mb": unit = "megabyte"
            default:   unit = "kilobyte"
            }
            return "\(m[1]) \(plural(m[1], unit))"
        }

        // Durations: 17s, 450ms, 3m, 2h -> spoken units.
        s = regex(s, #"(\d+(?:\.\d+)?)\s?ms\b"#) { m in
            "\(m[1]) \(plural(m[1], "millisecond"))"
        }
        s = regex(s, #"(\d+(?:\.\d+)?)s\b"#) { m in "\(m[1]) \(plural(m[1], "second"))" }
        s = regex(s, #"(\d+(?:\.\d+)?)h\b"#) { m in "\(m[1]) \(plural(m[1], "hour"))" }

        // Percent sign.
        s = regex(s, #"(\d+(?:\.\d+)?)\s?%"#) { m in "\(m[1]) percent" }

        // A leading minus on a number is a sign, not a hyphen: -20 -> "minus 20".
        s = regex(s, #"(^|[\s(])-(\d)"#) { m in "\(m[1])minus \(m[2])" }

        // Common abbreviations that are read letter-by-letter otherwise.
        let words: [(String, String)] = [
            ("RTF", "R T F"), ("TTFA", "T T F A"), ("CLI", "C L I"),
            ("PR", "P R"), ("CI", "C I"), ("repo", "repo"),
            ("&&", " and "), ("->", " to "),
        ]
        for (from, to) in words {
            s = s.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: from))\\b",
                with: to, options: .regularExpression)
        }

        // Collapse whitespace introduced by the substitutions.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Both engines produce steadier prosody when the input ends in a
        // terminator; without one the model tends to trail off or run on.
        if let last = s.last, !".!?".contains(last) { s += "." }
        return s
    }

    // MARK: - helpers

    private static func plural(_ number: String, _ unit: String) -> String {
        (Double(number) == 1.0) ? unit : unit + "s"
    }

    private static func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)th"
        default:
            switch n % 10 {
            case 1: return "\(n)st"
            case 2: return "\(n)nd"
            case 3: return "\(n)rd"
            default: return "\(n)th"
            }
        }
    }

    /// Replace every match, giving the callback the capture groups.
    private static func regex(
        _ s: String, _ pattern: String, _ body: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += body(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
