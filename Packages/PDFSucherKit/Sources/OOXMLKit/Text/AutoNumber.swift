// AutoNumber.swift — Task 7 (OOXMLKit)
// Text of DrawingML auto-numbered bullets (`a:buAutoNum@type`).
import Foundation

enum AutoNumber {
    /// `scheme` = <style><format>: style arabic | alphaLc | alphaUc | romanLc | romanUc, format Period ("3."),
    /// ParenR ("3)"), ParenBoth ("(3)"), Plain ("3"). Unknown schemes → arabicPeriod. Alphabetic numbering
    /// repeats the letter after z (27 → "aa", as PowerPoint does); numbers PowerPoint cannot show
    /// alphabetically or in roman (≤ 0, roman > 3999) fall back to arabic.
    static func text(scheme: String, number: Int) -> String {
        let styles: [(String, (Int) -> String?)] = [
            ("arabic", { String($0) }),
            ("alphaLc", { alpha($0, upper: false) }),
            ("alphaUc", { alpha($0, upper: true) }),
            ("romanLc", { roman($0)?.lowercased() }),
            ("romanUc", { roman($0) }),
        ]
        let formats: [(String, (String) -> String)] = [
            ("Period", { $0 + "." }), ("ParenR", { $0 + ")" }), ("ParenBoth", { "(" + $0 + ")" }), ("Plain", { $0 }),
        ]
        for (prefix, style) in styles where scheme.hasPrefix(prefix) {
            let rest = scheme.dropFirst(prefix.count)
            for (suffix, format) in formats where rest == suffix {
                return format(style(number) ?? String(number))
            }
        }
        return String(number) + "."
    }

    private static func alpha(_ n: Int, upper: Bool) -> String? {
        guard n >= 1, n <= 26 * 1000 else { return nil }
        let letter = Character(Unicode.Scalar(UInt8((upper ? 65 : 97) + (n - 1) % 26)))
        return String(repeating: letter, count: (n - 1) / 26 + 1)
    }

    private static func roman(_ n: Int) -> String? {
        guard n >= 1, n <= 3999 else { return nil }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var rest = n
        var out = ""
        for (value, digits) in table {
            while rest >= value { out += digits; rest -= value }
        }
        return out
    }
}
