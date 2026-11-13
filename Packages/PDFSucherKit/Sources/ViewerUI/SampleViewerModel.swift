// SampleViewerModel.swift — Task 4.3 (DEBUG only: SwiftUI previews and screenshots)
#if DEBUG
import CoreText
import Foundation
import Observation
import OutputKit
import SearchKit
import SwiftUI

/// Three generated PDFs with seven hit pages each, searched for „Vertrag“.
@MainActor @Observable
final class SampleViewerModel: ViewerModel {
    var queryText = "Vertrag"
    var hits: [DocumentHit]
    var query = ParsedQuery(terms: [.word("Vertrag")])
    var selection = PageSelection()
    var focusedPage: PageRef?
    let settings: GridSettings
    var indexStatus: IndexStatus = .problems(failed: ["Archiv/alt_beschaedigt.pdf"], noText: ["Scans/rechnung_2019.pdf"])
    var summary: String { ViewerText.summary(hits: hits) }
    var isSearching = false
    var isBrowsing = false
    let previewZoom = PreviewZoom()
    let ocrPreferences = OCRPreferences(defaults: UserDefaults(suiteName: "PDFSucher.Sample.OCR") ?? .standard)
    func stopRecognition() {}
    var isRecognitionStopped = false
    func resumeRecognition() {}
    func ocrText(for page: PageRef) async -> OCRPageText? { nil }
    let keyboard = KeyboardSettings(defaults: UserDefaults(suiteName: "PDFSucher.Sample.Keys") ?? .standard)
    var notice: String?
    var alertMessage: String?
    var alertOffersRemovingMissingPages = false
    func removeMissingPagesFromSelection() {}
    var isPreparingPrint = false

    init(settings: GridSettings = GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.Sample") ?? .standard)) {
        self.settings = settings
        hits = (try? SampleData.makeHits()) ?? []
        focusedPage = hits.first.map { PageRef(url: $0.url, pageIndex: $0.pageHits[0].pageIndex) }
    }

    var sources: [LoadedSourceRef] = []
    func openSources() {}
    func addSources(_ urls: [URL]) {}
    let searchHistory = SearchHistory(defaults: UserDefaults(suiteName: "Sample-\(UUID())")!)
    func noteSearchArrived() {}
    func chooseHistoryEntry(_ term: String) { queryText = term }
    var addPrompt: AddPrompt?
    func answerAddPrompt(_ choice: AddChoice, remember: Bool) { addPrompt = nil }
    func removeSource(_ url: URL) {}
    func removeAllSources() {}
    func printSelection() {}
    func saveSelection() {}
    func openInPreview(_ r: PageRef) {}

    /// Case-insensitive whole-word „Vertrag“, standing in for SearchKit's PageMatcher.
    static let highlighter: @MainActor (ParsedQuery) -> HighlightRanges? = { _ in
        { text in
            var ranges: [Range<String.Index>] = []
            var start = text.startIndex
            while let r = text.range(of: "vertrag", options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
                let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
                if !(before?.isLetter ?? false), !(after?.isLetter ?? false) { ranges.append(r) }
                start = r.upperBound
            }
            return ranges
        }
    }
}

enum SampleData {
    static func makeHits() throws -> [DocumentHit] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSucherSample", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let documents: [(String, [Int])] = [
            ("Verträge/vertrag_2024.pdf", [0, 2, 3, 6, 8, 11, 14]),
            ("Angebote/angebot_mueller.pdf", [1, 2, 4, 5, 7, 9, 10]),
            ("mietvertrag_buero.pdf", [0, 1, 3, 4, 6, 12, 13]),
        ]
        return try documents.enumerated().map { offset, entry in
            let (path, hitPages) = entry
            let url = dir.appendingPathComponent((path as NSString).lastPathComponent)
            let pages = (0..<15).map { i in
                hitPages.contains(i)
                    ? "Seite \(i + 1)\n\nDer Vertrag tritt am 1. Januar in Kraft. Änderungen am Vertrag bedürfen der Schriftform. "
                        + String(repeating: "Weitere Bestimmungen regeln Laufzeit, Kündigung und Haftung. ", count: 6)
                    : "Seite \(i + 1)\n\n" + String(repeating: "Allgemeine Angaben ohne den gesuchten Begriff. ", count: 8)
            }
            try writePDF(at: url, pages: pages)
            let pageHits = hitPages.map { PageHit(pageIndex: $0, matchCount: 2) }
            return DocumentHit(url: url, relativePath: path, modifiedAt: Date(timeIntervalSinceNow: -Double(offset) * 86_400),
                               pageHits: pageHits, totalMatches: pageHits.count * 2, relevance: Double(3 - offset),
                               sourceRoot: dir, pageCount: 15)
        }
    }

    private static func writePDF(at url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(),
                                                 CGPath(rect: box.insetBy(dx: 60, dy: 60), transform: nil), nil)
            ctx.beginPDFPage(nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

#Preview("PDFSucher") {
    ContentShell(model: SampleViewerModel(), highlighter: SampleViewerModel.highlighter)
        .frame(width: 1280, height: 860)
}
#endif
