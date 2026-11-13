// ThumbnailTile.swift — Task 4.3
import AppKit
import OutputKit
import SearchKit
import SwiftUI
import os

/// One hit page: thumbnail (loaded off the main actor) with checkbox and „S. n“ on it, top left
/// (Chris, Task 5.6), on a material background so they stay readable over the page.
struct ThumbnailTile: View {
    let ref: PageRef
    let size: CGSize
    let isSelected: Bool
    let isFocused: Bool
    let folderUnreachable: Bool
    let cache: ThumbnailCache
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    var style = TileStyle(hitFrame: false, badge: nil, dimmed: false, highlights: true)
    var highlightColor: RGBA = .yellow
    /// Text and word boxes of an OCR page (spec 1.2 §5): the marks are drawn from them.
    var ocrText: (@MainActor (PageRef) async -> OCRPageText?)?
    let onToggle: () -> Void
    let onFocus: () -> Void
    let onOpen: () -> Void

    private enum Phase: Equatable { case loading, image(NSImage), missing, unavailable }
    @State private var phase = Phase.loading
    @State private var recognized = false

    /// „Texterkennung“ on a PDF page whose text was recognized (images are recognized as a whole).
    nonisolated static func showsOCRBadge(isImage: Bool, ocr: OCRPageText?) -> Bool { !isImage && ocr != nil }

    private struct LoadID: Equatable {
        let ref: PageRef
        let width: Int, height: Int
        let highlightKey: String
    }

    var body: some View {
        ZStack { content.opacity(style.dimmed ? TileStyle.dimmedOpacity : 1) }
            .frame(width: size.width, height: size.height)
            .background(Color.secondary.opacity(0.08))
            .overlay {
                // Hit pages („Alle Seiten“) have the accent frame; a focused page without a hit gets a
                // primary frame, so it never looks like a hit page.
                let color: Color = style.hitFrame || (isFocused && !style.dimmed) ? .accentColor
                    : isFocused ? .primary : .secondary.opacity(0.35)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color, lineWidth: style.hitFrame || isFocused ? TileStyle.hitFrameWidth : 1)
                if isFocused, style.hitFrame {
                    // A hit page that also has the focus: an extra inner ring.
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary, lineWidth: 2).padding(TileStyle.hitFrameWidth)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if recognized {
                    // Icon only on narrow tiles; the label stays for VoiceOver.
                    Label(ViewerText.ocrBadge, systemImage: "text.viewfinder")
                        .labelStyle(size.width < 160 ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(4)
                        .accessibilityIdentifier("ocrBadge")
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge = style.badge {
                    Text("\(badge)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .padding(5)
                        .accessibilityLabel(ViewerText.matchBadge(badge))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onOpen)
            .simultaneousGesture(TapGesture().onEnded(onFocus))
            .help("Klick: groß anzeigen · Doppelklick: in Vorschau öffnen")
            // After the gestures, so a click on the tick does not also count as a click on the page.
            .overlay(alignment: .topLeading) {
                Toggle(isOn: Binding(get: { isSelected }, set: { _ in onFocus(); onToggle() })) {
                    Text(ViewerText.pageLabel(ref.pageIndex))
                        .font(.callout)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
            }
            .clipped()          // very narrow fixed-mode tiles: the label must not cover the next tile
            .contentShape(Rectangle())   // and its hidden part must not take clicks between the tiles
            .frame(width: max(size.width, 1))
            .task(id: LoadID(ref: ref, width: Self.round10(size.width), height: Self.round10(size.height),
                             highlightKey: highlightRanges == nil ? ""
                                : highlightKey + "|" + highlightColor.key + "|" + "\(HighlightGeometry.style(forTileWidth: size.width))")) {
                await load()
            }
            .onDisappear { phase = .loading }   // drop the bitmap when scrolled away; the cache keeps a bounded copy
            .accessibilityElement(children: .contain)
            .accessibilityLabel(style.badge.map { ViewerText.pageLabel(ref.pageIndex) + ", " + ViewerText.matchBadge($0) }
                                ?? ViewerText.pageLabel(ref.pageIndex))
            // The keyboard focus (arrow keys, space ticks) is otherwise only a border.
            .accessibilityAddTraits(isFocused ? .isSelected : [])
            .accessibilityAction(named: "Groß anzeigen", onFocus)
            .accessibilityAction(named: "In Vorschau öffnen", onOpen)
            .accessibilityAction(named: isSelected ? "Häkchen entfernen" : "Häkchen setzen", onToggle)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            // Scrolled back: a tile still in memory shows at once, without a spinner flashing.
            if let cached = cache.cachedImage(for: ref, size: size, highlightKey: highlightKey, highlighted: highlightRanges != nil,
                                              highlightColor: highlightColor) {
                Image(nsImage: cached).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        case .image(let image):
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        case .missing:
            placeholder(ViewerText.tilePlaceholder(fileExists: false, folderUnreachable: folderUnreachable), symbol: "doc.questionmark")
        case .unavailable:
            placeholder(ViewerText.tilePlaceholder(fileExists: true, folderUnreachable: folderUnreachable), symbol: "exclamationmark.triangle")
        }
    }

    /// Matches the cache's 10 pt key rounding so resizing does not restart every load per pixel.
    private static func round10(_ v: CGFloat) -> Int { Int((v / 10).rounded()) * 10 }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.large)
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(4)
    }

    private static let timing = Logger(subsystem: "local.pdfsucher", category: "TileTiming")

    private func load() async {
        guard size.width >= 1, size.height >= 1 else { return }
        let started = ContinuousClock.now
        // The OCR text is needed before drawing only for marks; otherwise the badge follows the thumbnail.
        var ocr = highlightRanges == nil ? nil : await ocrText?(ref)
        guard !Task.isCancelled else { return }
        let image = await cache.thumbnail(for: ref, size: size, highlightKey: highlightKey, highlightRanges: highlightRanges,
                                          highlightColor: highlightColor, ocr: ocr)
        guard !Task.isCancelled else { return }
        // The picture first; the badge's index lookup must not hold it back (spec 1.2.3).
        if let image {
            phase = .image(image)
            // `log stream --level debug --predicate 'category == "TileTiming"'` shows how long tiles wait (spec 1.2.3).
            let waited = ContinuousClock.now - started
            Self.timing.debug("tile shown after \(waited.components.seconds * 1000 + waited.components.attoseconds / 1_000_000_000_000_000) ms")
        }
        if highlightRanges == nil { ocr = await ocrText?(ref) }
        recognized = Self.showsOCRBadge(isImage: ImagePages.isImage(ref.url), ocr: ocr)
        guard !Task.isCancelled else { return }
        if image == nil {
            let path = ref.url.path
            let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
            guard !Task.isCancelled else { return }
            phase = exists ? .unavailable : .missing
        }
    }
}

/// Picks a label style at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
