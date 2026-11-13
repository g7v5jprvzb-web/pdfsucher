// ResultGridView.swift — Task 4.3
import AppKit
import OutputKit
import SearchKit
import SwiftUI
import os

/// One row per document, lazily built; tile size from `GridLayout` and the grid settings.
/// Arrow keys move the focused tile, space toggles its checkbox.
struct ResultGridView: View {
    static let padding: CGFloat = 10

    let model: any ViewerModel
    let cache: ThumbnailCache
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    /// The window's keyboard focus (spec 1.1 §9): the grid is `.grid`.
    let focus: FocusState<FocusArea?>.Binding
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    /// The tile the user just clicked (visible): focusing it needs no vertical scrolling.
    @State private var clickedTile: PageRef?

    /// Space for the tiles: the view minus padding and, with always-visible (legacy) scrollers, minus
    /// the vertical scroller, because fixed-mode tiles fill the width exactly.
    static func contentSize(of size: CGSize, scrollerStyle: NSScroller.Style) -> CGSize {
        let scroller = scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return CGSize(width: size.width - 2 * padding - scroller, height: size.height - 2 * padding)
    }

    var body: some View {
        let folderUnreachable = model.indexStatus == .unreachable
        GeometryReader { geometry in
            let metrics = GridLayout.metrics(
                available: Self.contentSize(of: geometry.size, scrollerStyle: scrollerStyle),
                rows: model.settings.rows,
                columns: model.settings.columns,
                mode: model.settings.columnsMode,
                rowHeader: DocumentRow.overhead(fontSize: model.settings.headerFontSize)
            )
            let tileSize = metrics.tileSize
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.hits) { hit in
                            DocumentRow(hit: hit, tileSize: tileSize, model: model, cache: cache, folderUnreachable: folderUnreachable,
                                        highlightKey: highlightKey, highlightRanges: highlightRanges,
                                        prefetchAhead: metrics.columns,
                                        onFocusTile: { ref in
                                            clickedTile = ref
                                            model.focusedPage = ref
                                            focus.wrappedValue = .grid
                                        })
                            .id(hit.id)
                            .onAppear { prefetchRows(after: hit, columns: metrics.columns, tileSize: tileSize) }
                        }
                    }
                    .padding(Self.padding)
                }
                .onAppear {
                    // Rebuilt (e.g. the preview moved, spec 1.1 §3): bring the focused row back into view.
                    guard let focused = model.focusedPage,
                          let row = model.hits.first(where: { $0.url == focused.url }) else { return }
                    proxy.scrollTo(row.id, anchor: .top)
                }
                .task {
                    // Measurement only (spec 1.2.3): `-uiTestAutoScrollMS <ms>` scrolls through every row once.
                    let step = UserDefaults.standard.integer(forKey: "uiTestAutoScrollMS")
                    guard step > 0 else { return }
                    let log = Logger(subsystem: "local.pdfsucher", category: "TileTiming")
                    var stable = 0, last = -1
                    while stable < 10 {
                        try? await Task.sleep(for: .milliseconds(200))
                        let count = model.hits.count
                        stable = count == last && count > 0 ? stable + 1 : 0
                        last = count
                    }
                    try? await Task.sleep(for: .seconds(3))
                    log.debug("autoscroll start \(model.hits.count) rows, step \(step) ms")
                    for id in model.hits.map(\.id) {
                        proxy.scrollTo(id, anchor: .top)
                        try? await Task.sleep(for: .milliseconds(step))
                    }
                    log.debug("autoscroll stop")
                }
                .onChange(of: metrics.columns, initial: true) { _, columns in
                    if model.settings.automaticColumns != columns { model.settings.automaticColumns = columns }
                }
                .onChange(of: model.focusedPage) { previous, focused in
                    let clicked = clickedTile
                    clickedTile = nil
                    if clicked != nil, clicked == focused { return }
                    // Only when the focus moves to another document: a row can be taller than the
                    // view (fixed mode, few pages per row), and left/right must not jump vertically.
                    guard let focused, previous?.url != focused.url,
                          let row = model.hits.first(where: { $0.url == focused.url }) else { return }
                    // Vertical only; each DocumentRow scrolls its own horizontal row to the tile.
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(row.id, anchor: .top) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
        .overlay { emptyState }
        .focusable()
        .focused(focus, equals: .grid)
        .focusEffectDisabled()
        // Space and Return (tick) go through the key router (spec 1.1 §7/§10); arrows stay here.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            handle(press.key)
        }
        .accessibilityIdentifier("resultGrid")
    }

    @ViewBuilder private var emptyState: some View {
        if model.hits.isEmpty {
            if model.sources.isEmpty {
                ContentUnavailableView("Ordner oder PDFs hinzufügen", systemImage: "plus.rectangle.on.folder",
                                       description: Text("Mit ⌘O öffnen oder ins Fenster ziehen. Ohne Suchbegriff erscheinen hier alle PDFs, mit Suchbegriff alle Trefferseiten."))
            } else if model.queryText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Keine PDFs", systemImage: "doc",
                                       description: Text("In den geladenen Quellen wurden (noch) keine PDFs gefunden."))
            } else {
                ContentUnavailableView("Keine Treffer", systemImage: "magnifyingglass",
                                       description: Text(ViewerText.noResults(query: model.queryText)))
            }
        }
    }

    /// Rows rendered ahead below a row that comes into view (spec 1.2.3).
    static let prefetchRows = 2

    /// Renders the first screen width of the next rows ahead, so scrolling down finds them ready.
    private func prefetchRows(after hit: DocumentHit, columns: Int, tileSize: CGSize) {
        guard let index = model.hits.firstIndex(where: { $0.id == hit.id }) else { return }
        let showAll = model.settings.showAllPages
        for next in model.hits.dropFirst(index + 1).prefix(Self.prefetchRows) {
            let first = DocumentRow.firstShownPosition(next, showAll: showAll)
            DocumentRow.prefetch(next, positions: first..<(first + max(columns, 1)), tileSize: tileSize, model: model, cache: cache,
                                 highlightKey: highlightKey, highlightRanges: highlightRanges)
        }
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        let direction: FocusNavigator.Direction
        switch key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }
        guard let next = FocusNavigator.next(from: model.focusedPage, direction: direction, hits: model.hits,
                                             showAllPages: model.settings.showAllPages) else { return .ignored }
        model.focusedPage = next
        return .handled
    }
}
