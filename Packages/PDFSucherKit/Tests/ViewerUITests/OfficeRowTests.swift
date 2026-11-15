import AppKit
import Foundation
import IndexKit
import OutputKit
import SearchKit
import SwiftUI
import Testing
import TestSupport
@testable import ViewerUI

/// 1.3 Teil B Task 8: Word/PowerPoint in rows and tiles – symbol, „vereinfacht“, placeholders, OCR badge, reload.
@Suite("Office rows and tiles")
@MainActor
struct OfficeRowTests {
    private func hit(_ name: String, kind: DocumentKind, pageCount: Int = 3, isSimplified: Bool = false) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/d/" + name), relativePath: name, modifiedAt: .distantPast, pageHits: [],
                    totalMatches: 0, relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: pageCount,
                    kind: kind, isSimplified: isSimplified)
    }

    @Test func rowSymbolsPerKind() {
        #expect(ViewerText.rowSymbol(hit("a.png", kind: .image)) == "photo")
        #expect(ViewerText.rowSymbol(hit("a.docx", kind: .word)) == "doc.richtext")
        #expect(ViewerText.rowSymbol(hit("a.pptx", kind: .powerpoint)) == "rectangle.inset.filled.on.rectangle")
        #expect(ViewerText.rowSymbol(hit("a.pdf", kind: .pdf)) == nil)
        #expect(ViewerText.kindLabel(.pdf) == "PDF")
        #expect(ViewerText.kindLabel(.word) == "Word")
        #expect(ViewerText.kindLabel(.powerpoint) == "PowerPoint")
        #expect(ViewerText.kindLabel(.image) == "Bild")
    }

    @Test func rowSymbolsExist() {
        for name in ["doc.richtext", "rectangle.inset.filled.on.rectangle"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    /// Review Focus 1: layout pages come back from `ocrPage` too; the badge is for recognized PDF pages only.
    @Test func officePagesShowNoOCRBadge() {
        let ocr = OCRPageText(text: "x", words: [])
        #expect(!ThumbnailTile.showsOCRBadge(kind: .word, ocr: ocr))
        #expect(!ThumbnailTile.showsOCRBadge(kind: .powerpoint, ocr: ocr))
        #expect(ThumbnailTile.showsOCRBadge(kind: .pdf, ocr: ocr))
        #expect(!ThumbnailTile.showsOCRBadge(kind: .image, ocr: ocr))
        #expect(!ThumbnailTile.showsOCRBadge(kind: .pdf, ocr: nil))
    }

    @Test func simplifiedOnlyForTextkit() throws {
        #expect(ViewerText.simplified == "vereinfacht")
        #expect(ViewerText.simplifiedHelp
                == "Vereinfachte Darstellung: Kopf- und Fußzeilen, Bilder und Formatvorlagen fehlen; der Text ist vollständig durchsuchbar.")
        #expect(DocumentRow.showsSimplifiedHint(hit("a.docx", kind: .word, isSimplified: true)))
        #expect(!DocumentRow.showsSimplifiedHint(hit("a.docx", kind: .word, isSimplified: false)))
        #expect(!DocumentRow.showsSimplifiedHint(hit("a.pptx", kind: .powerpoint)))
        #expect(!DocumentRow.showsSimplifiedHint(hit("a.pdf", kind: .pdf)))
#if DEBUG
        // The real row (ViewTests style, `fittingSize`): only a simplified document gets the extra hint in its header.
        // Page count 0 shows the one-line row hint instead of tiles, so the header decides the width.
        let plain = rowWidth(hit("Protokoll der Sitzung.docx", kind: .word, pageCount: 0, isSimplified: false))
        let simplified = rowWidth(hit("Protokoll der Sitzung.docx", kind: .word, pageCount: 0, isSimplified: true))
        #expect(simplified > plain + 20, "\(simplified) vs \(plain)")
        #expect(rowWidth(hit("Protokoll der Sitzung.pdf", kind: .pdf, pageCount: 0)) < plain + 20)
#endif
    }

    @Test func pendingOfficeRowText() {
        #expect(ViewerText.layoutPending == "Wird für die Anzeige vorbereitet …")
        #expect(ViewerText.rowHint(hit("a.docx", kind: .word, pageCount: 0)) == ViewerText.layoutPending)
        #expect(ViewerText.rowHint(hit("a.pptx", kind: .powerpoint, pageCount: 0)) == ViewerText.layoutPending)
        #expect(ViewerText.rowHint(hit("a.pdf", kind: .pdf, pageCount: 0)) == ViewerText.pagesPending)
        let broken = DocumentHit(url: URL(fileURLWithPath: "/d/x.docx"), relativePath: "x.docx", modifiedAt: .distantPast,
                                 pageHits: [], totalMatches: 0, relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"),
                                 pageCount: 0, isUnreadable: true, kind: .word)
        #expect(ViewerText.rowHint(broken) == ViewerText.unreadableRow)
    }

    @Test func officeTilePlaceholderIsPreparing() {
        #expect(ThumbnailTile.placeholderPhase(kind: .word, fileExists: true) == .preparing)
        #expect(ThumbnailTile.placeholderPhase(kind: .powerpoint, fileExists: true) == .preparing)
        #expect(ThumbnailTile.placeholderPhase(kind: .pdf, fileExists: true) == .unavailable)
        #expect(ThumbnailTile.placeholderPhase(kind: .image, fileExists: true) == .unavailable)
        #expect(ThumbnailTile.placeholderPhase(kind: .word, fileExists: false) == .missing)
        #expect(ViewerText.previewPreparing == "Vorschau wird vorbereitet …")
        #expect(ViewerText.tileHelp(kind: .word) == "Klick: groß anzeigen · Doppelklick: Original öffnen")
        #expect(ViewerText.tileHelp(kind: .powerpoint) == "Klick: groß anzeigen · Doppelklick: Original öffnen")
        #expect(ViewerText.tileHelp(kind: .pdf) == "Klick: groß anzeigen · Doppelklick: in Vorschau öffnen")
        // Only a laid-out PowerPoint whose slide picture is missing is reported (Task 9 relays it out).
        #expect(ThumbnailTile.reportsSlidesMissing(kind: .powerpoint, pageCount: 4, phase: .preparing))
        #expect(!ThumbnailTile.reportsSlidesMissing(kind: .powerpoint, pageCount: 0, phase: .preparing))
        #expect(!ThumbnailTile.reportsSlidesMissing(kind: .word, pageCount: 4, phase: .preparing))
        #expect(!ThumbnailTile.reportsSlidesMissing(kind: .powerpoint, pageCount: 4, phase: .missing))
    }

    @Test func tileReloadsOnLayoutRevisionForOfficeOnly() {
        let size = CGSize(width: 200, height: 283)
        func id(_ name: String, _ kind: DocumentKind, revision: Int) -> ThumbnailTile.LoadID {
            ThumbnailTile.loadID(ref: PageRef(url: URL(fileURLWithPath: "/d/" + name), pageIndex: 0), size: size,
                                 highlightKey: "", kind: kind, layoutRevision: revision)
        }
        #expect(id("a.docx", .word, revision: 1) != id("a.docx", .word, revision: 2))
        #expect(id("a.pptx", .powerpoint, revision: 1) != id("a.pptx", .powerpoint, revision: 2))
        #expect(id("a.pdf", .pdf, revision: 1) == id("a.pdf", .pdf, revision: 2))
        #expect(id("a.png", .image, revision: 1) == id("a.png", .image, revision: 2))
    }

    /// Review of Task 8: an Office tile that shows its picture already does not reload on layout progress; one still
    /// waiting (preparing, loading) does.
    @Test func tileWithPictureIgnoresLayoutRevision() {
        let ref = PageRef(url: URL(fileURLWithPath: "/d/a.pptx"), pageIndex: 0)
        let size = CGSize(width: 200, height: 150)
        func id(revision: Int, showsImage: Bool) -> ThumbnailTile.LoadID {
            ThumbnailTile.loadID(ref: ref, size: size, highlightKey: "", kind: .powerpoint, layoutRevision: revision,
                                 showsImage: showsImage)
        }
        #expect(id(revision: 1, showsImage: true) == id(revision: 2, showsImage: true))
        #expect(id(revision: 1, showsImage: false) != id(revision: 2, showsImage: false))
    }

    /// SlideKit wiring: another page provider (`foreignPagesRevision`) reloads every Word/PowerPoint tile, also one
    /// showing its picture; PDFs and images ignore it.
    @Test func tileReloadsWhenThePagesChange() {
        let size = CGSize(width: 200, height: 150)
        func id(_ name: String, _ kind: DocumentKind, pages: Int, showsImage: Bool = true) -> ThumbnailTile.LoadID {
            ThumbnailTile.loadID(ref: PageRef(url: URL(fileURLWithPath: "/d/" + name), pageIndex: 0), size: size,
                                 highlightKey: "", kind: kind, layoutRevision: 1, pagesRevision: pages, showsImage: showsImage)
        }
        #expect(id("a.pptx", .powerpoint, pages: 0) != id("a.pptx", .powerpoint, pages: 1))
        #expect(id("a.pptx", .powerpoint, pages: 0, showsImage: false) != id("a.pptx", .powerpoint, pages: 1, showsImage: false))
        #expect(id("a.docx", .word, pages: 0) != id("a.docx", .word, pages: 1))
        #expect(id("a.pdf", .pdf, pages: 0) == id("a.pdf", .pdf, pages: 1))
        #expect(id("a.png", .image, pages: 0) == id("a.png", .image, pages: 1))
    }

#if DEBUG
    private func rowWidth(_ hit: DocumentHit) -> CGFloat {
        let model = SampleViewerModel(settings: GridSettings(defaults: UserDefaults(suiteName: "PDFSucher.OfficeRow.\(UUID())")!))
        model.hits = [hit]
        let row = DocumentRow(hit: hit, baseTileSize: CGSize(width: 100, height: 141), shapes: PageShapes(), model: model, cache: ThumbnailCache(scale: 1),
                              folderUnreachable: false, highlightKey: "", highlightRanges: nil, onFocusTile: { _ in })
        return NSHostingView(rootView: row).fittingSize.width
    }
#endif
}
