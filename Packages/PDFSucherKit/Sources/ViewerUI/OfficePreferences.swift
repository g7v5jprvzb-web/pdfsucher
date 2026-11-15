// OfficePreferences.swift — 1.3 Part B (spec 1.3)
import Foundation
import IndexKit
import Observation

/// „Word- und PowerPoint-Dateien durchsuchen“, on by default, persisted under „office.include“.
/// Off: folders no longer list Word/PowerPoint files and new drops/⌘O ignore them; single files
/// already loaded stay (like single images with „Bilder durchsuchen“ off).
/// Task 12: „PowerPoint-Darstellung“ („office.powerPointRenderer“ = "slideKit" (default) | "quickLook") and
/// „Fehlende Schriften“ („office.fontSubstitution“ = "powerPoint" (default) | "similar"); unknown values read as default.
/// Same keys and values as SlideKit's `OfficeRenderSettings`; the app maps the choices by raw value to
/// `PowerPointRenderer` / `FontSubstitution` (`OfficeKit.OfficeRendering`), since ViewerUI must not depend on SlideKit.
@MainActor @Observable public final class OfficePreferences {
    enum Key {
        static let includeOffice = "office.include"
        static let powerPointRenderer = "office.powerPointRenderer"
        static let fontSubstitution = "office.fontSubstitution"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedIncludeOffice: Bool
    private var storedRenderer: OfficeRendererChoice
    private var storedFonts: OfficeFontChoice

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedIncludeOffice = defaults.object(forKey: Key.includeOffice) == nil ? true : defaults.bool(forKey: Key.includeOffice)
        storedRenderer = defaults.string(forKey: Key.powerPointRenderer).flatMap(OfficeRendererChoice.init(rawValue:)) ?? .slideKit
        storedFonts = defaults.string(forKey: Key.fontSubstitution).flatMap(OfficeFontChoice.init(rawValue:)) ?? .powerPoint
    }

    public var includeOffice: Bool {
        get { storedIncludeOffice }
        set { storedIncludeOffice = newValue; defaults.set(newValue, forKey: Key.includeOffice) }
    }

    public var powerPointRenderer: OfficeRendererChoice {
        get { storedRenderer }
        set { storedRenderer = newValue; defaults.set(newValue.rawValue, forKey: Key.powerPointRenderer) }
    }

    public var fontSubstitution: OfficeFontChoice {
        get { storedFonts }
        set { storedFonts = newValue; defaults.set(newValue.rawValue, forKey: Key.fontSubstitution) }
    }
}

/// „PowerPoint-Darstellung“ as the settings UI offers it: the own viewer (SlideKit, default) or macOS's Quick Look.
/// Raw values = stored values = SlideKit's `PowerPointRenderer` raw values (mapped by the app, not imported here).
public enum OfficeRendererChoice: String, CaseIterable, Sendable {
    case slideKit
    case quickLook
}

/// „Fehlende Schriften“ as the settings UI offers it: a font the deck uses but the Mac lacks is replaced like
/// PowerPoint does (default; measured: PowerPoint takes Calibri) or by a similar font. Only for the own viewer.
/// Raw values = stored values = OOXMLKit's `FontSubstitution` raw values (mapped by the app).
public enum OfficeFontChoice: String, CaseIterable, Sendable {
    case powerPoint
    case similar
}
