// FolderBarSettings.swift — Ordnerleiste: visibility and width, remembered
import Foundation
import Observation

/// Whether the folder bar shows and how wide it is (⌃⌘S, toolbar button, menu Darstellung).
@MainActor @Observable public final class FolderBarSettings {
    public static let widthRange: ClosedRange<Double> = 160...480
    public static let defaultWidth: Double = 240
    enum Key {
        static let visible = "layout.folderBar.visible"
        static let width = "layout.folderBar.width"
        static let open = "layout.folderBar.open"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Key.visible) }
    }

    public var width: Double {
        didSet {
            let clamped = Self.clamp(width)
            if clamped != width { width = clamped; return }
            defaults.set(width, forKey: Key.width)
        }
    }

    /// Folders of „Quellen“ opened (true) or closed (false) by hand or by `reveal`, by path; kept, also for the
    /// next start. Others use their default: a source root open, a subfolder closed. Folders that left the
    /// tree stay listed: a volume or a source may come back.
    public private(set) var openState: [String: Bool] {
        didSet { if openState != oldValue { scheduleExpandedWrite() } }
    }
    /// One write per main-actor turn: ⌥-click opens a whole subtree folder by folder, and each write stores
    /// the whole state (10,000 files: 2,500 single writes took 6.5 s).
    @ObservationIgnored private(set) var expandedWrite: Task<Void, Never>?

    private func scheduleExpandedWrite() {
        guard expandedWrite == nil else { return }
        expandedWrite = Task { @MainActor [weak self] in
            guard let self else { return }
            self.expandedWrite = nil
            self.defaults.set(self.openState, forKey: Key.open)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openState = (defaults.dictionary(forKey: Key.open) ?? [:]).compactMapValues { $0 as? Bool }
        isVisible = defaults.bool(forKey: Key.visible)
        width = Self.clamp((defaults.object(forKey: Key.width) as? NSNumber)?.doubleValue ?? Self.defaultWidth)
    }

    public func toggle() { isVisible.toggle() }

    /// `byDefault`: for a folder never opened or closed (true for a source root).
    public func isExpanded(_ folder: URL, byDefault: Bool = false) -> Bool {
        openState[folder.standardizedFileURL.path] ?? byDefault
    }

    public func isExpanded(_ node: FolderNode) -> Bool { isExpanded(node.url, byDefault: node.isSourceRoot) }

    /// A state equal to `byDefault` is not stored (review: an ⌥-click closing a big subtree stores nothing).
    public func setExpanded(_ folder: URL, _ open: Bool, byDefault: Bool = false) {
        let path = folder.standardizedFileURL.path
        if open == byDefault { openState.removeValue(forKey: path) } else { openState[path] = open }
    }

    /// What `reveal` did: the first chosen folder in tree order (to scroll to), and whether every chosen
    /// folder was in the tree (otherwise the sidebar tries again with the next tree).
    public struct Reveal: Equatable, Sendable {
        public var first: String?
        public var allFound: Bool
    }

    /// Opens the tree down to the chosen folders (their parents; each folder itself stays as it was).
    @discardableResult
    public func reveal(_ filter: FolderFilter, in tree: [FolderNode]) -> Reveal {
        let wanted = Set(filter.folders.map(\.standardizedFileURL.path))
        guard !wanted.isEmpty else { return Reveal(first: nil, allFound: true) }
        var open = openState
        var first: String?
        var found = Set<String>()
        func walk(_ node: FolderNode, _ parents: [FolderNode]) {
            let path = node.url.standardizedFileURL.path
            if wanted.contains(path) {
                for parent in parents {
                    let key = parent.url.standardizedFileURL.path
                    if parent.isSourceRoot { open.removeValue(forKey: key) } else { open[key] = true }   // root: open by default
                }
                if first == nil { first = path }
                found.insert(path)
            }
            // Only down where a chosen folder can lie.
            for child in node.children where wanted.contains(where: { $0.hasPrefix(child.url.standardizedFileURL.path) }) {
                walk(child, parents + [node])
            }
        }
        for root in tree where root.kind == .folder { walk(root, []) }
        if open != openState { openState = open }
        return Reveal(first: first, allFound: found == wanted)
    }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, widthRange.lowerBound), widthRange.upperBound) : defaultWidth
    }
}
