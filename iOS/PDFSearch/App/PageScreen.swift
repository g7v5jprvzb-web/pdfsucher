import PDFKit
import PDFSearchCore
import SwiftUI
import UIKit

/// Screen 3: one PDF page large, hits highlighted, jump from hit to hit, page strip below.
struct PageScreen: View {
    @Environment(AppModel.self) private var model
    let fileID: Int64
    let startPage: Int

    @State private var proxy = PDFViewProxy()
    @State private var pdf: PDFDocument?
    @State private var hits: [PDFSelection] = []
    @State private var hitIndex = 0
    @State private var currentPage = 1
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let document = model.document(fileID) {
                VStack(spacing: 0) {
                    pageArea
                    Divider()
                    bottomBar(document)
                }
                .toolbar { toolbar(document) }
                .task(id: fileID) { load(document) }
            } else {
                ContentUnavailableView("Treffer nicht mehr vorhanden", systemImage: "doc.questionmark",
                                       description: Text("Die Suche hat sich geändert."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder private var pageArea: some View {
        if let pdf {
            PDFKitView(document: pdf, highlights: hits, startPage: startPage, proxy: proxy) { page in
                currentPage = page
            }
        } else if loadFailed {
            ContentUnavailableView("PDF lässt sich nicht öffnen", systemImage: "exclamationmark.triangle",
                                   description: Text("Die Datei wurde verschoben, gelöscht oder ist geschützt."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ document: DocumentHit) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(document.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle(document)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            HitsOnlyToggle()
                .scaleEffect(0.9)
            if let url = model.url(of: document) {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Teilen")
            }
            GlobalSearchButton()
        }
    }

    private func subtitle(_ document: DocumentHit) -> String {
        var text = "S. \(currentPage)/\(document.pageCount)"
        if !hits.isEmpty { text += " · Treffer \(hitIndex + 1)/\(hits.count)" }
        return text
    }

    private func bottomBar(_ document: DocumentHit) -> some View {
        let hitPages = Set(document.hitPageNumbers)
        let pages = model.visiblePages(of: document)
        let selected = model.isSelected(fileID: document.fileID, page: currentPage)
        return VStack(spacing: 4) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(pages, id: \.self) { page in
                            Button {
                                proxy.go(toPage: page)
                            } label: {
                                Text("\(page)")
                                    .font(.system(size: 10, weight: page == currentPage ? .bold : .regular))
                                    .foregroundStyle(page == currentPage ? Color.accentColor : Color.primary)
                                    .frame(width: 28, height: 38, alignment: .bottom)
                                    .padding(.bottom, 2)
                                    .background(Color(.systemBackground).opacity(hitPages.contains(page) ? 1 : 0.6))
                                    .overlay(alignment: .top) {
                                        if hitPages.contains(page) { Rectangle().fill(Color.yellow).frame(height: 4) }
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(page == currentPage ? Color.accentColor : Color(.separator),
                                                          lineWidth: page == currentPage ? 2 : 0.5)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .buttonStyle(.plain)
                            .id(page)
                            .accessibilityLabel("Seite \(page)\(hitPages.contains(page) ? ", Treffer" : "")")
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 40)
                .onChange(of: currentPage) { _, page in
                    withAnimation { reader.scrollTo(page, anchor: .center) }
                }
            }

            HStack(spacing: 4) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.up").frame(width: 44, height: 38)
                }
                .buttonStyle(.bordered)
                .disabled(hits.isEmpty)
                .accessibilityLabel("Vorheriger Treffer")
                Button { step(1) } label: {
                    Image(systemName: "chevron.down").frame(width: 44, height: 38)
                }
                .buttonStyle(.bordered)
                .disabled(hits.isEmpty)
                .accessibilityLabel("Nächster Treffer")
                Text(model.hitsOnly && !document.pages.isEmpty ? "\(pages.count) Trefferseiten" : "Alle \(pages.count) Seiten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                Button {
                    model.toggleSelection(document, page: currentPage)
                } label: {
                    Label(selected ? "Ausgewählt" : "Auswählen", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: 38)
                }
                .buttonStyle(.borderedProminent)
                .tint(selected ? Color.accentColor : Color.accentColor.opacity(0.18))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func load(_ document: DocumentHit) {
        guard pdf == nil else { return }
        model.rememberQuery()
        guard let url = model.url(of: document), let opened = PDFDocument(url: url), !opened.isLocked else {
            loadFailed = true
            return
        }
        currentPage = startPage
        hits = Self.findHits(in: opened, terms: model.result.terms)
        hitIndex = hits.firstIndex { Self.pageNumber(of: $0, in: opened) >= startPage } ?? 0
        pdf = opened
    }

    private func step(_ direction: Int) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + direction + hits.count) % hits.count
        proxy.go(to: hits[hitIndex])
    }

    /// All occurrences of the search terms, in reading order, coloured for highlighting.
    static func findHits(in document: PDFDocument, terms: [String]) -> [PDFSelection] {
        var found: [PDFSelection] = []
        for term in terms where !term.isEmpty {
            found += document.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive])
        }
        for selection in found {
            selection.color = UIColor.systemYellow.withAlphaComponent(0.55)
        }
        return found.sorted { a, b in
            let pa = pageNumber(of: a, in: document), pb = pageNumber(of: b, in: document)
            if pa != pb { return pa < pb }
            guard let page = a.pages.first else { return false }
            let ra = a.bounds(for: page), rb = b.bounds(for: page)
            return ra.maxY != rb.maxY ? ra.maxY > rb.maxY : ra.minX < rb.minX
        }
    }

    static func pageNumber(of selection: PDFSelection, in document: PDFDocument) -> Int {
        guard let page = selection.pages.first else { return 0 }
        return document.index(for: page) + 1
    }
}

/// Lets SwiftUI buttons drive the PDFView.
@MainActor
final class PDFViewProxy {
    weak var view: PDFView?

    func go(toPage number: Int) {
        guard let view, let page = view.document?.page(at: number - 1) else { return }
        view.go(to: page)
    }

    func go(to selection: PDFSelection) {
        guard let view else { return }
        view.go(to: selection)
        view.setCurrentSelection(selection, animate: true)
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let highlights: [PDFSelection]
    let startPage: Int
    let proxy: PDFViewProxy
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .systemGroupedBackground
        view.document = document
        view.highlightedSelections = highlights
        if let page = document.page(at: startPage - 1) { view.go(to: page) }
        proxy.view = view
        context.coordinator.onPageChange = onPageChange
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak view, coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let view, let page = view.currentPage, let document = view.document else { return }
                coordinator.onPageChange?(document.index(for: page) + 1)
            }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        if view.document !== document { view.document = document }
        view.highlightedSelections = highlights
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.observer = nil
    }

    @MainActor
    final class Coordinator {
        var onPageChange: ((Int) -> Void)?
        var observer: (any NSObjectProtocol)?
    }
}
