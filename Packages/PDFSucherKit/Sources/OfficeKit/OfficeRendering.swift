// OfficeRendering.swift — 1.3 Teil B Task 12 + SlideKit wiring: the PowerPoint display choice with main's types.
import Foundation
import Synchronization
@_exported import enum OOXMLKit.FontSubstitution
@_exported import enum SlideKit.PowerPointRenderer

/// How PowerPoint pages are drawn and read: „PowerPoint-Darstellung“ (`office.powerPointRenderer`, SlideKit's
/// `PowerPointRenderer`) and „Fehlende Schriften“ (`office.fontSubstitution`, OOXMLKit's `FontSubstitution`).
/// The settings UI (ViewerUI, which must not depend on SlideKit) keeps its own choices with the same raw values;
/// the app maps them with `init(powerPointRawValue:fontsRawValue:)`. A change that alters the PowerPoint renderer
/// identity lays every PowerPoint document out again.
public struct OfficeRendering: Sendable, Equatable {
    public var powerPoint: PowerPointRenderer
    public var fonts: FontSubstitution

    public init(powerPoint: PowerPointRenderer = .slideKit, fonts: FontSubstitution = .powerPoint) {
        self.powerPoint = powerPoint
        self.fonts = fonts
    }

    /// From the stored raw values (as `OfficeRenderSettings` reads them); unknown values give the defaults.
    public init(powerPointRawValue: String, fontsRawValue: String) {
        self.init(powerPoint: PowerPointRenderer(rawValue: powerPointRawValue) ?? .slideKit,
                  fonts: FontSubstitution(rawValue: fontsRawValue) ?? .powerPoint)
    }

    public static let `default` = OfficeRendering()
}

/// The current choice, shared by the layout sources (`OfficeLayoutSource` reads it at every call) and the app,
/// which keeps it in step with its settings.
public final class PowerPointDisplaySetting: Sendable {
    /// The app's setting (the `AppModel` writes it; `FolderIndex` and `OfficePages` read it by default).
    public static let shared = PowerPointDisplaySetting()
    private let state: Mutex<OfficeRendering>

    public init(_ value: OfficeRendering = .default) { state = Mutex(value) }

    public var value: OfficeRendering {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
