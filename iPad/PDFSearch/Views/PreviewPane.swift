import IndexKit
import MediaKit
import PDFKit
import SearchKit
import SwiftUI

/// The big preview next to the tiles: the PDF with highlighted matches, or the JPEG with its
/// recognized matches framed; previous/next match.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    @Binding var fullScreen: Bool
    @State private var matchIndex = 0
    @State private var matchCount = 0
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let target = model.preview {
                Group {
                    if target.hit.kind == .image {
                        ImagePreview(target: target, query: model.parsedQuery, store: model.store(for: target.hit),
                                     matchIndex: $matchIndex, matchCount: $matchCount)
                    } else {
                        PDFPreview(target: target, query: model.parsedQuery,
                                   matchIndex: $matchIndex, matchCount: $matchCount, currentPage: $currentPage)
                    }
                }
                .id(target.hit.id)
            } else {
                ContentUnavailableView("Keine Vorschau", systemImage: "doc.richtext",
                                       description: Text("Tippe auf eine Kachel."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGray6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("previewPane")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.preview?.hit.displayName ?? "Vorschau")
                    .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("previewTitle")
                if let hit = model.preview?.hit {
                    Text(hit.kind == .image ? "JPEG · Texterkennung" : "Seite \(currentPage + 1) von \(hit.pageCount)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("previewPage")
                }
            }
            Spacer()
            if matchCount > 0 {
                Text("Treffer \(matchIndex + 1) von \(matchCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("matchCounter")
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Vorheriger Treffer")
                .accessibilityIdentifier("prevMatch")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Nächster Treffer")
                .accessibilityIdentifier("nextMatch")
            Button { fullScreen.toggle() } label: {
                Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(fullScreen ? "Vollbild beenden" : "Vollbild")
            .accessibilityIdentifier("fullScreen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = (matchIndex + delta + matchCount) % matchCount
    }
}

// MARK: PDF

struct PDFPreview: UIViewRepresentable {
    let target: PreviewTarget
    let query: ParsedQuery
    @Binding var matchIndex: Int
    @Binding var matchCount: Int
    @Binding var currentPage: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = .systemGray6
        context.coordinator.view = view
        context.coordinator.onPage = { page in currentPage = page }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let c = context.coordinator
        if c.url != target.hit.url || c.query != query {
            c.url = target.hit.url
            c.query = query
            c.token = nil
            let document = PDFDocument(url: target.hit.url)
            view.document = document
            c.matches = document.map { Self.matches(in: $0, pages: target.hit.pageHits.map(\.pageIndex), query: query) } ?? []
            view.highlightedSelections = c.matches.map(\.selection)
        }
        if c.token != target.token {
            c.token = target.token
            let first = c.matches.firstIndex { $0.page == target.page }
            let count = c.matches.count
            DispatchQueue.main.async {
                matchCount = count
                matchIndex = first ?? 0
            }
            c.shown = first
            // A freshly set document is not laid out yet and ignores `go(to:)`: navigate after layout.
            let page = target.page
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                if let first { c.show(first) } else if let pdfPage = view.document?.page(at: page) { view.go(to: pdfPage) }
            }
            return
        }
        if c.shown != matchIndex, matchIndex < c.matches.count { c.show(matchIndex) }
    }

    struct Match { let page: Int; let selection: PDFSelection }

    /// The query's matches on the hit pages, found with the same matcher the index uses.
    static func matches(in document: PDFDocument, pages: [Int], query: ParsedQuery) -> [Match] {
        guard !query.isEmpty else { return [] }
        let matcher = PageMatcher(query)
        var result: [Match] = []
        for index in pages {
            guard let page = document.page(at: index), let text = page.string,
                  let ranges = matcher.ranges(in: text) else { continue }
            for range in ranges {
                guard let selection = page.selection(for: NSRange(range, in: text)) else { continue }
                selection.color = UIColor.systemYellow.withAlphaComponent(0.55)
                result.append(Match(page: index, selection: selection))
            }
        }
        return result
    }

    @MainActor final class Coordinator: NSObject {
        weak var view: PDFView?
        var url: URL?
        var query: ParsedQuery?
        var token: UUID?
        var matches: [Match] = []
        var shown: Int?
        var onPage: ((Int) -> Void)?

        func show(_ index: Int) {
            guard let view, index < matches.count else { return }
            shown = index
            let selection = matches[index].selection
            view.go(to: selection)
            view.setCurrentSelection(selection, animate: true)
        }

        @objc func pageChanged() {
            guard let view, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            DispatchQueue.main.async { self.onPage?(index) }
        }
    }
}

// MARK: JPEG

struct ImagePreview: View {
    let target: PreviewTarget
    let query: ParsedQuery
    let store: IndexStore?
    @Binding var matchIndex: Int
    @Binding var matchCount: Int
    @State private var image: UIImage?
    @State private var boxes: [CGRect] = []

    var body: some View {
        GeometryReader { geo in
            if let image {
                let fitted = Self.fit(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().frame(width: fitted.width, height: fitted.height)
                    ForEach(Array(boxes.enumerated()), id: \.offset) { index, box in
                        let current = index == matchIndex
                        Rectangle()
                            .fill(Color.yellow.opacity(current ? 0.35 : 0.2))
                            .overlay(Rectangle().strokeBorder(current ? Color.orange : Color.yellow, lineWidth: current ? 3 : 2))
                            .frame(width: max(box.width * fitted.width, 4) + 4, height: max(box.height * fitted.height, 4) + 4)
                            .offset(x: box.minX * fitted.width - 2, y: box.minY * fitted.height - 2)
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
        .task(id: "\(target.hit.url.path)#\(target.token)") { await load() }
    }

    private func load() async {
        let url = target.hit.url
        let path = target.hit.relativePath
        let query = query
        let store = store
        let result = await Task.detached { () -> (UIImage?, [CGRect]) in
            let image = UIImage(contentsOfFile: url.path).flatMap { $0.preparingForDisplay() }
            guard let page = try? store?.ocrPage(relativePath: path, pageIndex: 0),
                  let ranges = PageMatcher(query).ranges(in: page.text) else { return (image, []) }
            let nsRanges = ranges.map { NSRange($0, in: page.text) }
            return (image, HighlightBoxes.rects(for: nsRanges, in: page.words))
        }.value
        image = result.0
        boxes = result.1
        matchCount = boxes.count
        matchIndex = 0
    }

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
