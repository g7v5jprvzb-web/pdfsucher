// ContentShell.swift — Task 4.3
import AppKit
import SearchKit
import SwiftUI

/// The main window content: search bar, view controls and status, the large page view above, left or
/// right of the result grid (resizable split, spec 1.1 §3), selection bar at the bottom. Spec §4.3.
public struct ContentShell: View {
    /// Smallest window content width; both toolbar lines must fit into it.
    static let minWidth: CGFloat = 960
    static let toolbarPadding: CGFloat = 12
    private let model: any ViewerModel
    private let highlighter: @MainActor (ParsedQuery) -> HighlightRanges?
    @State private var cache: ThumbnailCache
    private let tileDisk: TileDiskCache
    @State private var isDropTargeted = false
    @State private var searchHandle = SearchFieldHandle()
    /// Keyboard focus of preview and grid; the search field (AppKit) is asked through `searchHandle`.
    @FocusState private var focus: FocusArea?
    /// The last area that had the focus, given back after the preview moved (the views are rebuilt).
    @State private var lastFocus: FocusArea?

    /// - Parameter highlighter: turns the current query into a `HighlightRanges` closure. Phase 5
    ///   passes `{ q in { PageMatcher(q).ranges(in: $0) ?? [] } }`; the default draws no highlights.
    /// - Parameter tileDisk: the tiles on disk; screenshot tests pass one in a temp folder.
    public init(model: some ViewerModel, highlighter: @escaping @MainActor (ParsedQuery) -> HighlightRanges? = { _ in nil },
                tileDisk: TileDiskCache = .standard) {
        self.model = model
        self.highlighter = highlighter
        self.tileDisk = tileDisk
        _cache = State(initialValue: ThumbnailCache(disk: tileDisk, foreign: model.foreignPages))
    }

    private var highlight: (key: String, ranges: HighlightRanges?) {
        let query = model.query
        return (String(describing: query), query.isEmpty ? nil : highlighter(query))
    }

    private var preview: some View {
        PageDetailView(model: model, cache: cache, highlightKey: highlight.key, highlightRanges: highlight.ranges)
            .focusable()
            .focused($focus, equals: .preview)
            .focusEffectDisabled()
    }

    private var grid: some View {
        ResultGridView(model: model, cache: cache, highlightKey: highlight.key, highlightRanges: highlight.ranges, focus: $focus)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ToolbarArea(model: model, search: searchHandle)
            .padding(.horizontal, Self.toolbarPadding)
            .padding(.vertical, 8)
            Divider()
            // Ordnerleiste at the left, full height under the toolbar; the folder filter header over preview and grid.
            HStack(spacing: 0) {
                if model.folderBar.isVisible {
                    FolderSidebar(model: model)
                        .frame(width: CGFloat(model.folderBar.width))
                    FolderBarHandle(settings: model.folderBar)
                }
                VStack(spacing: 0) {
                    FolderFilterHeader(model: model)
                    // The divider position is remembered per preview position (1.2.1 §2).
                    PreviewSplit(position: model.settings.previewPosition, settings: model.settings, zoom: model.previewZoom) { preview } grid: { grid }
                }
            }
            Divider()
            SelectionBar(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: Self.minWidth, minHeight: 560)
        .background(WindowFrameKeeper(load: { [settings = model.settings] in settings.mainWindowFrame },
                                      save: { [settings = model.settings] in settings.mainWindowFrame = $0 }))
        .acceptsFileDrops(isTargeted: $isDropTargeted) { model.addSources($0) }
        .onChange(of: focus) { _, area in if let area { lastFocus = area } }
        // Another PowerPoint renderer or font choice: a new tile cache with the new provider (its tiles in memory were
        // drawn by the old one; on disk the content version keeps them apart).
        // The old cache's prefetch stops first, so it does not reopen decks with the old fonts.
        .onChange(of: model.foreignPagesRevision) { _, _ in
            cache.prefetch([])
            cache = ThumbnailCache(disk: tileDisk, foreign: model.foreignPages)
        }
        .onChange(of: model.settings.previewPosition) { _, _ in
            let area = lastFocus
            Task { @MainActor in focus = area }      // after the rebuilt views are in the window
        }
        .background(KeyRouterInstaller(model: model, search: searchHandle,
                                       focus: { focus }, setFocus: { area in if area != .search { focus = area } }))
        .overlay { if isDropTargeted { DropOverlay() } }
        .sheet(item: Binding(get: { model.addPrompt },
                             set: { if $0 == nil { model.answerAddPrompt(.cancel, remember: false) } })) { prompt in
            AddSourcesSheet(prompt: prompt) { choice, remember in model.answerAddPrompt(choice, remember: remember) }
        }
        .alert(model.alertMessage ?? "", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })) {
            if model.alertOffersRemovingMissingPages {
                Button("Fehlende Seiten aus Auswahl entfernen") { model.removeMissingPagesFromSelection() }
            }
            Button("OK", role: .cancel) { model.alertMessage = nil }
        }
    }
}

/// The folder bar's right edge: drag to change its width (remembered).
struct FolderBarHandle: View {
    let settings: FolderBarSettings
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = start ?? settings.width
                    if start == nil { start = base }
                    settings.width = base + value.translation.width
                }
                .onEnded { _ in start = nil })
            .accessibilityIdentifier("folderBarHandle")
    }
}

/// Second toolbar line: how the grid and the preview look (1.1: more controls than fit next to the
/// status, which now has its own third line).
struct ViewControls: View {
    let model: any ViewerModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.folderBar.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(model.folderBar.isVisible ? ViewerText.hideFolderBar + " (⌃⌘S)" : ViewerText.showFolderBar + " (⌃⌘S)")
            .accessibilityLabel(model.folderBar.isVisible ? ViewerText.hideFolderBar : ViewerText.showFolderBar)
            .accessibilityIdentifier("folderBarToggle")
            GridControls(settings: model.settings)
            Spacer(minLength: 0)
        }
    }
}

/// The three toolbar lines: search, view controls, status (1.2.2 §2: in the chosen font size).
struct ToolbarArea: View {
    let model: any ViewerModel
    let search: SearchFieldHandle

    var body: some View {
        let size = model.settings.effectiveToolbarFontSize
        VStack(alignment: .leading, spacing: 6) {
            SearchBar(model: model, search: search)
            ViewControls(model: model)
            IndexStatusView(model: model)
        }
        .font(.system(size: size))
        .controlSize(ToolbarScale.controlSize(size))
    }
}
