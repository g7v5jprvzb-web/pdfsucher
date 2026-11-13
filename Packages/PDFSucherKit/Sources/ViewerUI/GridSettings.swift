// GridSettings.swift — Task 4.1
import CoreGraphics
import Foundation
import Observation
import SearchKit

/// Pages per row: a fixed number (1…10) or as many as fit the window width (Chris, Task 5.4).
public enum ColumnsMode: String, CaseIterable, Sendable {
    case fixed, automatic
}

/// A colour as sRGB components 0…1 (spec 1.1 §14 „Markierungsfarbe“).
public struct RGBA: Codable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// Bright yellow, the default highlight colour.
    public static let yellow = RGBA(r: 1, g: 1, b: 0, a: 1)
    /// Stable text for cache keys.
    var key: String { String(format: "%.3f,%.3f,%.3f,%.3f", r, g, b, a) }
}

/// Where the large page view sits relative to the grid (spec 1.1 §3).
public enum PreviewPosition: String, CaseIterable, Sendable {
    case top, leading, trailing
}

/// Grid and search preferences, clamped and persisted in `UserDefaults`.
@MainActor @Observable public final class GridSettings {
    public static let range = 1...10
    enum Key {
        static let rows = "grid.rows"
        static let columns = "grid.columns"
        static let sort = "grid.sort"
        static let partialWords = "search.partialWords"
        static let columnsMode = "grid.columnsMode"
        static let debounceMs = "search.debounceMs"
        static let headerFontSize = "grid.headerFontSize"
        static let zoomLevels = "preview.zoomLevels"
        static let previewPosition = "layout.previewPosition"
        static let showAllPages = "grid.showAllPages"
        static let highlightColor = "highlight.color"
        static let addSourcesPolicy = "sources.addPolicy"
        static let toolbarFontSize = "toolbar.fontSize"
        static let mainWindowFrame = "window.main.frame"
        static let settingsWindowOrigin = "window.settings.origin"
        static let settingsTab = "settings.tab"
        static func split(_ position: PreviewPosition) -> String { "layout.split.\(position.rawValue)" }
    }

    // MARK: 1.2.2 §2 toolbar font

    /// Font size of the toolbar in pt (10…20, any value); nil = the system size.
    public var toolbarFontSize: Double? {
        get { storedToolbarFontSize }
        set {
            storedToolbarFontSize = newValue.map { min(max($0, ToolbarScale.range.lowerBound), ToolbarScale.range.upperBound) }
            defaults.set(storedToolbarFontSize, forKey: Key.toolbarFontSize)
        }
    }
    private var storedToolbarFontSize: Double?
    public var effectiveToolbarFontSize: Double { toolbarFontSize ?? ToolbarScale.systemSize }
    public func resetToolbarFont() {
        storedToolbarFontSize = nil
        defaults.removeObject(forKey: Key.toolbarFontSize)
    }

    // MARK: 1.2.1 §2 window and splitter

    /// Frame of the main window (AppKit screen coordinates), nil until it was moved or resized once.
    public var mainWindowFrame: CGRect? {
        get { WindowPlacement.parseFrame(defaults.string(forKey: Key.mainWindowFrame)) }
        set { defaults.set(newValue.map(WindowPlacement.format), forKey: Key.mainWindowFrame) }
    }

    /// Top-left corner of the settings window (its size follows the chosen tab).
    public var settingsWindowOrigin: CGPoint? {
        get { WindowPlacement.parsePoint(defaults.string(forKey: Key.settingsWindowOrigin)) }
        set { defaults.set(newValue.map(WindowPlacement.format), forKey: Key.settingsWindowOrigin) }
    }

    /// The settings tab chosen last.
    public var settingsTab: SettingsTab {
        get { storedSettingsTab }
        set { storedSettingsTab = newValue; defaults.set(newValue.rawValue, forKey: Key.settingsTab) }
    }
    private var storedSettingsTab: SettingsTab

    /// Share of the preview in the split, one value per preview position.
    private var storedSplits: [PreviewPosition: Double]
    public func previewFraction(for position: PreviewPosition) -> Double { storedSplits[position] ?? SplitMath.defaultFraction(position) }
    public func setPreviewFraction(_ value: Double, for position: PreviewPosition) {
        let clamped = SplitMath.clampFraction(value, for: position)
        storedSplits[position] = clamped
        defaults.set(clamped, forKey: Key.split(position))
    }

    /// 1.2.1 §1: what dropping or opening sources does while others are loaded.
    private var storedAddSourcesPolicy: AddSourcesPolicy
    public var addSourcesPolicy: AddSourcesPolicy {
        get { storedAddSourcesPolicy }
        set { storedAddSourcesPolicy = newValue; defaults.set(newValue.rawValue, forKey: Key.addSourcesPolicy) }
    }

    /// Spec 1.1 §14: colour of the match marks on tiles and in the large preview.
    private var storedHighlightColor: RGBA
    public var highlightColor: RGBA {
        get { storedHighlightColor }
        set {
            storedHighlightColor = newValue
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Key.highlightColor) }
        }
    }

    public func resetHighlightColor() {
        storedHighlightColor = .yellow
        defaults.removeObject(forKey: Key.highlightColor)
    }

    /// Spec 1.1 §8: every page of each hit document, hit pages marked (default off).
    private var storedShowAllPages: Bool
    public var showAllPages: Bool {
        get { storedShowAllPages }
        set { storedShowAllPages = newValue; defaults.set(newValue, forKey: Key.showAllPages) }
    }

    private var storedPreviewPosition: PreviewPosition
    public var previewPosition: PreviewPosition {
        get { storedPreviewPosition }
        set { storedPreviewPosition = newValue; defaults.set(newValue.rawValue, forKey: Key.previewPosition) }
    }

    /// §13: share of the page width per zoom level 1…4, in percent (10…100, 5 % steps).
    public static let defaultZoomLevels = [100, 75, 50, 35]
    public static let zoomLevelRange = 10...100
    public static let zoomLevelStep = 5
    public private(set) var zoomLevelFractions: [Int]

    public func setZoomLevelFraction(_ level: Int, to percent: Int) {
        guard (1...4).contains(level) else { return }
        zoomLevelFractions[level - 1] = Self.validZoomLevel(percent)
        defaults.set(zoomLevelFractions, forKey: Key.zoomLevels)
    }

    public func resetZoomLevels() {
        zoomLevelFractions = Self.defaultZoomLevels
        defaults.removeObject(forKey: Key.zoomLevels)
    }

    static func validZoomLevel(_ value: Int) -> Int {
        let clamped = min(max(value, zoomLevelRange.lowerBound), zoomLevelRange.upperBound)
        return (clamped / zoomLevelStep) * zoomLevelStep
    }

    /// Row header font size in pt (spec 1.1 §1): 12…28 in 2 pt steps, default 16.
    public static let headerFontRange = 12...28
    public static let headerFontStep = 2
    private var storedHeaderFontSize: Int

    public var headerFontSize: Int {
        get { storedHeaderFontSize }
        set { storedHeaderFontSize = Self.validHeaderFont(newValue); defaults.set(storedHeaderFontSize, forKey: Key.headerFontSize) }
    }
    public var canIncreaseHeaderFont: Bool { headerFontSize < Self.headerFontRange.upperBound }
    public var canDecreaseHeaderFont: Bool { headerFontSize > Self.headerFontRange.lowerBound }
    public func increaseHeaderFont() { headerFontSize += Self.headerFontStep }
    public func decreaseHeaderFont() { headerFontSize -= Self.headerFontStep }

    /// Clamped to 12…28 and rounded down to the 2 pt grid.
    static func validHeaderFont(_ value: Int) -> Int {
        let clamped = min(max(value, headerFontRange.lowerBound), headerFontRange.upperBound)
        return clamped - (clamped - headerFontRange.lowerBound) % headerFontStep
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedRows: Int
    private var storedColumns: Int
    private var storedSort: SortMode
    private var storedPartialWords: Bool
    private var storedColumnsMode: ColumnsMode
    private var storedDebounceMs: Int

    /// Choices for the delay after the last keystroke before searching (Chris, Task 5.5).
    public static let debounceChoices = [50, 150]

    /// Delay after the last keystroke in milliseconds: 50 (default) or 150; anything else becomes 50.
    public var debounceMs: Int {
        get { storedDebounceMs }
        set { storedDebounceMs = Self.validDebounce(newValue); defaults.set(storedDebounceMs, forKey: Key.debounceMs) }
    }

    public var columnsMode: ColumnsMode {
        get { storedColumnsMode }
        set { storedColumnsMode = newValue; defaults.set(newValue.rawValue, forKey: Key.columnsMode) }
    }

    /// The row count sets the tile size only in automatic mode; in fixed mode the pages per row fill
    /// the width and the grid scrolls (Chris, Task 5.4, option A).
    public var rowsApply: Bool { columnsMode == .automatic }

    /// Pages per row the grid currently shows in automatic mode (set by the grid, not persisted).
    public var automaticColumns = 0

    public var rows: Int {
        get { storedRows }
        set { storedRows = Self.clamp(newValue); defaults.set(storedRows, forKey: Key.rows) }
    }

    public var columns: Int {
        get { storedColumns }
        set { storedColumns = Self.clamp(newValue); defaults.set(storedColumns, forKey: Key.columns) }
    }

    public var sort: SortMode {
        get { storedSort }
        set { storedSort = newValue; defaults.set(newValue.rawValue, forKey: Key.sort) }
    }

    public var partialWords: Bool {
        get { storedPartialWords }
        set { storedPartialWords = newValue; defaults.set(newValue, forKey: Key.partialWords) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let has = { (key: String) in defaults.object(forKey: key) != nil }
        storedRows = Self.clamp(has(Key.rows) ? defaults.integer(forKey: Key.rows) : 3)
        storedColumns = Self.clamp(has(Key.columns) ? defaults.integer(forKey: Key.columns) : 5)
        storedSort = defaults.string(forKey: Key.sort).flatMap(SortMode.init(rawValue:)) ?? .matchCount
        storedPartialWords = has(Key.partialWords) ? defaults.bool(forKey: Key.partialWords) : false
        storedColumnsMode = defaults.string(forKey: Key.columnsMode).flatMap(ColumnsMode.init(rawValue:)) ?? .fixed
        storedDebounceMs = Self.validDebounce(defaults.integer(forKey: Key.debounceMs))
        storedShowAllPages = defaults.bool(forKey: Key.showAllPages)
        storedHighlightColor = defaults.data(forKey: Key.highlightColor).flatMap { try? JSONDecoder().decode(RGBA.self, from: $0) } ?? .yellow
        storedPreviewPosition = defaults.string(forKey: Key.previewPosition).flatMap(PreviewPosition.init(rawValue:)) ?? .top
        let levels = (defaults.array(forKey: Key.zoomLevels) as? [Int]).map { $0.map(Self.validZoomLevel) }
        zoomLevelFractions = levels?.count == 4 ? levels! : Self.defaultZoomLevels
        storedToolbarFontSize = (defaults.object(forKey: Key.toolbarFontSize) as? NSNumber).map(\.doubleValue)
            .flatMap { ToolbarScale.range.contains($0) ? $0 : nil }
        storedSettingsTab = defaults.string(forKey: Key.settingsTab).flatMap(SettingsTab.init(rawValue:)) ?? .general
        storedSplits = Dictionary(uniqueKeysWithValues: PreviewPosition.allCases.compactMap { position in
            (defaults.object(forKey: Key.split(position)) as? NSNumber).map { (position, SplitMath.clampFraction($0.doubleValue, for: position)) }
        })
        storedAddSourcesPolicy = defaults.string(forKey: Key.addSourcesPolicy).flatMap(AddSourcesPolicy.init(rawValue:)) ?? .ask
        storedHeaderFontSize = Self.validHeaderFont(has(Key.headerFontSize) ? defaults.integer(forKey: Key.headerFontSize) : 16)
    }

    static func validDebounce(_ value: Int) -> Int {
        debounceChoices.contains(value) ? value : debounceChoices[0]
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
