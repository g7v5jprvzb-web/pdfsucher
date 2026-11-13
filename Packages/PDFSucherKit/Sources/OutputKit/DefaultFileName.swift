// DefaultFileName.swift — Task 3.1
import Foundation

/// Suggested name for a merged PDF: `Auswahl_<Suchbegriff>_<yyyy-MM-dd>.pdf`.
public enum DefaultFileName {
    /// Byte budget for the search-term segment; keeps the whole name far below APFS' 255-byte limit.
    static let maxTermBytes = 120

    /// `calendar` supplies the time zone; the date is always written with Gregorian years.
    public static func make(searchTerm: String, date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let d = gregorian.dateComponents([.year, .month, .day], from: date)
        let day = "\(pad(d.year ?? 0, 4))-\(pad(d.month ?? 0, 2))-\(pad(d.day ?? 0, 2))"
        let term = sanitize(searchTerm)
        return term.isEmpty ? "Auswahl_\(day).pdf" : "Auswahl_\(term)_\(day).pdf"
    }

    /// Zero-width joiners (Persian, Indic scripts, emoji sequences) and tag characters
    /// (subdivision flags) are invisible format characters that still carry meaning.
    private static func isKeptFormat(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{200C}" || scalar == "\u{200D}" || (0xE0020...0xE007F).contains(scalar.value)
    }
    private static let forbidden = Set(#"/:\*?"<>|"#.unicodeScalars)

    static func sanitize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .format, !isKeptFormat(scalar) {
                continue // soft hyphen, bidi overrides, BOM: invisible, and bidi overrides can spoof names
            }
            let bad = forbidden.contains(scalar) || category == .control
                || category == .lineSeparator || category == .paragraphSeparator
            let piece: Unicode.Scalar = bad ? "-" : scalar
            if piece == "-", scalars.last == "-" { continue }
            scalars.append(piece)
        }
        var out = String(scalars)
        out = trim(out)
        if out.utf8.count > maxTermBytes {
            var cut = ""
            for ch in out {
                if cut.utf8.count + String(ch).utf8.count > maxTermBytes { break }
                cut.append(ch)
            }
            out = trim(cut)
        }
        return out
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let digits = String(n)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{200C}\u{200D}")))
    }
}
