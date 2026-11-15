// OfficeRenderSettings.swift — persisted Office rendering choices (values only; the settings UI lives in the app).
import Foundation
@_exported import enum OOXMLKit.FontSubstitution
@_exported import enum OOXMLKit.OfficeFontUse

/// Which renderer shows PowerPoint files. Default `.slideKit` (Chris' decision, 2026-11-13); Quick Look stays
/// selectable.
public enum PowerPointRenderer: String, Sendable, CaseIterable {
    case slideKit, quickLook
}

/// UserDefaults keys and readers for the Office settings. Raw values are the enums' `rawValue`s; a missing or
/// unknown value gives the default.
public struct OfficeRenderSettings: Sendable {
    /// Raw values "powerPoint" / "similar" (`FontSubstitution`). Pass the value to `SlideDeck(url:fontSubstitution:)`.
    public static let fontSubstitutionKey = "office.fontSubstitution"
    /// Raw values "slideKit" / "quickLook" (`PowerPointRenderer`).
    public static let powerPointRendererKey = "office.powerPointRenderer"

    /// Raw values "all" / "bundled" / "off" (`OfficeFontUse`, default all): Office's own fonts. OOXMLKit reads it
    /// itself, once, before the first font is resolved; a change takes effect at the next app start.
    public static let officeFontsKey = OfficeFontUse.settingKey

    public static func officeFonts(from defaults: UserDefaults) -> OfficeFontUse {
        defaults.string(forKey: officeFontsKey).flatMap(OfficeFontUse.init(rawValue:)) ?? .all
    }

    public static func fontSubstitution(from defaults: UserDefaults) -> FontSubstitution {
        defaults.string(forKey: fontSubstitutionKey).flatMap(FontSubstitution.init(rawValue:)) ?? .powerPoint
    }

    public static func powerPointRenderer(from defaults: UserDefaults) -> PowerPointRenderer {
        defaults.string(forKey: powerPointRendererKey).flatMap(PowerPointRenderer.init(rawValue:)) ?? .slideKit
    }
}
