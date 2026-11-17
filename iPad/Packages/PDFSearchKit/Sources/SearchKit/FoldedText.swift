// FoldedText.swift — Task 2.2
import Foundation

/// Case- and diacritic-folded copy of a text that remembers, for every folded
/// character, which original character produced it. Folding can change length
/// (`ß` → `ss`, `ﬁ` → `fi`, decomposed `u` + `¨` → `u`), so ranges found in
/// `folded` must be mapped back with `originalRange(of:)` before highlighting.
///
/// Each original Character is folded on its own, with the parser's options.
/// Fast path: a scalar below U+0250 (ASCII, Latin-1, Latin Extended-A/B) that is not
/// followed by a scalar ≥ U+0300 (where combining marks start) is a Character of its
/// own; it is folded through a precomputed table. Everything else goes through
/// Foundation folding, one Character at a time.
public struct FoldedText: Sendable {
    /// The folded text as UTF-16 code units (what regular expressions run on).
    let units: [UInt16]
    private let original: String
    private let originalUTF16Count: Int
    /// Segments in order. A run segment maps folded units 1:1 onto original units;
    /// a character segment maps any folded units onto one original Character.
    private let foldedStart: [Int]
    private let originalStart: [Int]
    private let originalLength: [Int]
    private let isRun: [Bool]

    public var folded: String { String(decoding: units, as: UTF16.self) }

    public init(_ original: String) {
        self.original = original
        let scalars = Array(original.unicodeScalars)
        var out: [UInt16] = []
        out.reserveCapacity(original.utf8.count)
        var fStart: [Int] = [], oStart: [Int] = [], oLen: [Int] = [], run: [Bool] = []
        var oOffset = 0

        func addRunUnit(_ u: UInt16) {
            if let last = run.indices.last, run[last],
               fStart[last] + oLen[last] == out.count,
               oStart[last] + oLen[last] == oOffset {
                oLen[last] += 1
            } else {
                fStart.append(out.count); oStart.append(oOffset); oLen.append(1); run.append(true)
            }
            out.append(u)
            oOffset += 1
        }
        // Raw pointers into the shared, immutable table: element access through the
        // arrays themselves would retain/release one shared buffer from every core.
        let tableUnits = FoldTable.units
        let tableStart = FoldTable.start
        func isFast(_ i: Int) -> Bool {
            scalars[i].value < FoldTable.limit && (i + 1 == scalars.count || scalars[i + 1].value < 0x300)
        }

        var i = 0
        while i < scalars.count {
            if isFast(i) {
                let v = Int(scalars[i].value)
                let lo = tableStart[v], hi = tableStart[v + 1]
                if hi - lo == 1 {
                    addRunUnit(tableUnits[lo])
                } else {
                    if hi > lo {
                        fStart.append(out.count); oStart.append(oOffset); oLen.append(1); run.append(false)
                        for x in lo..<hi { out.append(tableUnits[x]) }
                    }
                    oOffset += 1
                }
                i += 1
            } else {
                var k = i + 1
                while k < scalars.count && !isFast(k) { k += 1 }
                var chunk = String.UnicodeScalarView()
                chunk.append(contentsOf: scalars[i..<k])
                for ch in String(chunk) {
                    let oLength = ch.utf16.count
                    let piece = Array(SearchFolding.fold(String(ch)).utf16)
                    if !piece.isEmpty {
                        fStart.append(out.count); oStart.append(oOffset); oLen.append(oLength); run.append(false)
                        out.append(contentsOf: piece)
                    }
                    oOffset += oLength
                }
                i = k
            }
        }
        self.units = out
        self.originalUTF16Count = oOffset
        self.foldedStart = fStart
        self.originalStart = oStart
        self.originalLength = oLen
        self.isRun = run
    }

    /// For hot paths prefer the UTF-16 variants: this one measures offsets from the start.
    public func originalRange(of foldedRange: Range<String.Index>) -> Range<String.Index> {
        let f = folded
        let lower = f.utf16.distance(from: f.startIndex, to: foldedRange.lowerBound)
        let upper = f.utf16.distance(from: f.startIndex, to: foldedRange.upperBound)
        return originalRange(utf16Lower: lower, utf16Upper: upper)
    }

    /// Same as `originalRange(of:)` for UTF-16 offsets into `folded` (as `NSRange` gives them).
    func originalRange(utf16Lower lower: Int, utf16Upper upper: Int) -> Range<String.Index> {
        let r = originalOffsets(utf16Lower: lower, utf16Upper: upper)
        return index(r.lowerBound)..<index(r.upperBound)
    }

    /// UTF-16 offsets into the original text for UTF-16 offsets into `folded`.
    func originalOffsets(utf16Lower lower: Int, utf16Upper upper: Int) -> Range<Int> {
        let lo = originalLowerOffset(lower)
        let hi = upper > lower ? max(lo, originalUpperOffset(upper)) : lo
        return lo..<hi
    }

    func index(_ utf16Offset: Int) -> String.Index {
        String.Index(utf16Offset: utf16Offset, in: original)
    }

    /// Original offset where the folded unit at `offset` comes from (text end past the last one).
    private func originalLowerOffset(_ offset: Int) -> Int {
        guard let seg = segment(containing: offset) else { return originalUTF16Count }
        return isRun[seg] ? originalStart[seg] + (offset - foldedStart[seg]) : originalStart[seg]
    }

    /// Original offset just after the character that produced folded unit `offset - 1`.
    private func originalUpperOffset(_ offset: Int) -> Int {
        guard offset > 0, let seg = segment(containing: offset - 1) else { return 0 }
        return isRun[seg] ? originalStart[seg] + (offset - foldedStart[seg])
                          : originalStart[seg] + originalLength[seg]
    }

    /// Index of the segment whose folded UTF-16 span contains `offset`.
    private func segment(containing offset: Int) -> Int? {
        guard offset >= 0, offset < units.count else { return nil }
        var lo = 0, hi = foldedStart.count - 1
        while lo < hi {  // last segment with start <= offset
            let mid = (lo + hi + 1) / 2
            if foldedStart[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Folded UTF-16 units for every scalar below `limit`, computed once with the same
/// Foundation folding as everything else.
private enum FoldTable {
    static let limit: UInt32 = 0x250
    /// Folded units of scalar v are `units[start[v]..<start[v + 1]]`. Allocated once
    /// and never freed or written again, so sharing the pointers across threads is safe.
    nonisolated(unsafe) static let units: UnsafePointer<UInt16> = table.units
    nonisolated(unsafe) static let start: UnsafePointer<Int> = table.start

    nonisolated(unsafe) private static let table: (units: UnsafePointer<UInt16>, start: UnsafePointer<Int>) = {
        var units: [UInt16] = [], start: [Int] = []
        for v in 0..<limit {
            start.append(units.count)
            if let s = Unicode.Scalar(v) { units += SearchFolding.fold(String(Character(s))).utf16 }
        }
        start.append(units.count)
        let u = UnsafeMutablePointer<UInt16>.allocate(capacity: units.count)
        u.initialize(from: units, count: units.count)
        let st = UnsafeMutablePointer<Int>.allocate(capacity: start.count)
        st.initialize(from: start, count: start.count)
        return (UnsafePointer(u), UnsafePointer(st))
    }()
}
