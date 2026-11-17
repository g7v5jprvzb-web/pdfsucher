// PerfCorpus.swift — shared by the index perf test (Task 1.4) and the end-to-end measurement (Task 5.5)
import Foundation

/// Deterministic generator (SplitMix64) so the corpus is identical on every run.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds the perf corpus: German-ish words from syllables, fixed list, fixed seed.
public enum PerfCorpus {
    public static let wordsPerPage = 120     // 15 source lines, ~21 rendered (max ~30); a test page holds ~49
    public static let syllables = ["ver", "trag", "an", "ge", "bot", "rech", "nung", "lie", "fer", "schein",
                            "mie", "te", "kauf", "preis", "zah", "lung", "frist", "en", "de", "be",
                            "ginn", "ar", "beit", "geb", "er", "steu", "kos", "ten", "stel", "le",
                            "auf", "um", "satz", "bank", "kon", "to", "haus", "halt", "plan", "ung"]

    public static func wordList(count: Int = 2_000, using rng: inout SeededGenerator) -> [String] {
        var words = Set<String>()
        var ordered: [String] = []
        while ordered.count < count {
            let parts = Int.random(in: 2...4, using: &rng)
            var w = (0..<parts).map { _ in syllables.randomElement(using: &rng)! }.joined()
            if Bool.random(using: &rng) { w = w.prefix(1).uppercased() + w.dropFirst() }
            if words.insert(w.lowercased()).inserted { ordered.append(w) }
        }
        return ordered
    }

    public static func page(_ words: [String], using rng: inout SeededGenerator) -> String {
        var lines: [String] = []
        var line: [String] = []
        for _ in 0..<wordsPerPage {
            line.append(words.randomElement(using: &rng)!)
            if line.count == 8 { lines.append(line.joined(separator: " ")); line = [] }
        }
        if !line.isEmpty { lines.append(line.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}
