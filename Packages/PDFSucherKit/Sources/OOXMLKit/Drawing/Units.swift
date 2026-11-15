// Units.swift — Task 3 (OOXMLKit)
// DrawingML unit conversions. EMU = 1/914400 inch = 1/12700 pt; angles in 60000ths of a degree;
// percentages in 100000ths (ST_PositivePercentage / ST_Percentage).
import Foundation

public enum Units {
    public static let emuPerPoint = 12700.0
    public static let emuPerInch = 914400.0

    public static func points(fromEMU emu: Double) -> Double { emu / emuPerPoint }
    public static func points(fromEMU emu: Int) -> Double { Double(emu) / emuPerPoint }
    public static func inches(fromEMU emu: Double) -> Double { emu / emuPerInch }
    public static func inches(fromEMU emu: Int) -> Double { Double(emu) / emuPerInch }
    /// 60000ths of a degree → degrees.
    public static func degrees(fromAngle angle: Double) -> Double { angle / 60000 }
    /// 100000ths → fraction (50000 → 0.5).
    public static func fraction(fromPercent value: Double) -> Double { value / 100000 }

    /// ST_Percentage text: transitional "50000" (100000ths) or strict "50%" (optionally fractional).
    /// Returns a fraction (0.5), nil for missing/unparseable input.
    public static func parsePercentage(_ text: String?) -> Double? {
        guard let text else { return nil }
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("%") {
            guard let v = Double(s.dropLast().trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
            return v / 100
        }
        guard let v = Double(s), v.isFinite else { return nil }
        return v / 100000
    }
}
