import Testing
import Foundation
import PDFKit
import OutputKit
import TestSupport

@Suite("Merger")
struct MergerTests {
    let dir: URL
    let a: URL
    let b: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
        a = dir.appendingPathComponent("A.pdf")
        b = dir.appendingPathComponent("B.pdf")
        try PDFFixtures.makePDF(at: a, pages: ["Alpha null", "Alpha eins", "Alpha zwei"])
        try PDFFixtures.makePDF(at: b, pages: ["Beta null", "Beta eins"])
    }

    private func texts(_ doc: PDFDocument) -> [String] {
        (0..<doc.pageCount).map { doc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    @Test func mergeKeepsOrderAcrossFiles() throws {
        let doc = try Merger().makeDocument([
            PageRef(url: a, pageIndex: 2), PageRef(url: b, pageIndex: 1), PageRef(url: a, pageIndex: 1),
        ])
        #expect(texts(doc) == ["Alpha zwei", "Beta eins", "Alpha eins"])
    }

    @Test func mergeReportsMissingFile() throws {
        try FileManager.default.removeItem(at: b)
        #expect(throws: OutputError.cannotOpen(b)) {
            try Merger().makeDocument([PageRef(url: a, pageIndex: 0), PageRef(url: b, pageIndex: 0)])
        }
    }

    @Test func mergeReportsNonPdfFile() throws {
        let fake = dir.appendingPathComponent("kaputt.pdf")
        try Data("not a pdf".utf8).write(to: fake)
        #expect(throws: OutputError.cannotOpen(fake)) {
            try Merger().makeDocument([PageRef(url: fake, pageIndex: 0)])
        }
    }

    @Test func mergeReportsLockedFile() throws {
        let locked = dir.appendingPathComponent("locked.pdf")
        let ok = PDFDocument(url: a)!.write(to: locked, withOptions: [
            .userPasswordOption: "geheim", .ownerPasswordOption: "geheim",
        ])
        try #require(ok)
        #expect(throws: OutputError.cannotOpen(locked)) {
            try Merger().makeDocument([PageRef(url: locked, pageIndex: 0)])
        }
    }

    @Test func mergeRejectsBadPage() {
        let tooHigh = PageRef(url: b, pageIndex: 2)
        #expect(throws: OutputError.pageOutOfRange(tooHigh)) { try Merger().makeDocument([tooHigh]) }
        let negative = PageRef(url: b, pageIndex: -1)
        #expect(throws: OutputError.pageOutOfRange(negative)) { try Merger().makeDocument([negative]) }
    }

    @Test func mergeEmptyThrows() {
        #expect(throws: OutputError.emptySelection) { try Merger().makeDocument([]) }
        let out = dir.appendingPathComponent("leer.pdf")
        #expect(throws: OutputError.emptySelection) { try Merger().write([], to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func mergeAllowsSamePageTwice() throws {
        let doc = try Merger().makeDocument([PageRef(url: a, pageIndex: 0), PageRef(url: a, pageIndex: 0)])
        #expect(texts(doc) == ["Alpha null", "Alpha null"])
    }

    @Test func mergeLeavesSourcesUntouched() throws {
        let before = try Data(contentsOf: a)
        _ = try Merger().makeDocument([PageRef(url: a, pageIndex: 1)])
        #expect(try Data(contentsOf: a) == before)
        #expect(PDFDocument(url: a)!.pageCount == 3)
    }

    @Test func writeCreatesReadablePdf() throws {
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Merger().write([PageRef(url: b, pageIndex: 0), PageRef(url: a, pageIndex: 2)], to: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(texts(doc) == ["Beta null", "Alpha zwei"])
    }

    @Test func writeReplacesExistingFile() throws {
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Data("alt".utf8).write(to: out)
        try Merger().write([PageRef(url: a, pageIndex: 0)], to: out)
        #expect(texts(try #require(PDFDocument(url: out))) == ["Alpha null"])
    }

    @Test func writeCanOverwriteOneOfItsSources() throws {
        // The save dialog lets the user pick a source file as destination.
        try Merger().write([PageRef(url: b, pageIndex: 1), PageRef(url: a, pageIndex: 0), PageRef(url: a, pageIndex: 2)], to: a)
        #expect(texts(try #require(PDFDocument(url: a))) == ["Beta eins", "Alpha null", "Alpha zwei"])
    }

    @Test func writeReportsUnwritableDestination() throws {
        let out = dir.appendingPathComponent("gibt-es-nicht/Auswahl.pdf")
        let error = #expect(throws: OutputError.self) {
            try Merger().write([PageRef(url: a, pageIndex: 0)], to: out)
        }
        guard case .writeFailed(let url, let reason) = error else { Issue.record("expected writeFailed, got \(String(describing: error))"); return }
        #expect(url == out)
        #expect(!reason.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test(.enabled(if: getuid() != 0, "root ignores directory permissions"))
    func writeFailedCarriesReason() throws {
        let locked = dir.appendingPathComponent("nur-lesen", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let out = locked.appendingPathComponent("Auswahl.pdf")
        let error = #expect(throws: OutputError.self) {
            try Merger().write([PageRef(url: a, pageIndex: 0)], to: out)
        }
        guard case .writeFailed(let url, let reason) = error else { Issue.record("expected writeFailed, got \(String(describing: error))"); return }
        #expect(url == out)
        #expect(!reason.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func failedMergeKeepsExistingFileAndWritesNothing() throws {
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Data("alt".utf8).write(to: out)
        try FileManager.default.removeItem(at: b)
        #expect(throws: OutputError.cannotOpen(b)) {
            try Merger().write([PageRef(url: a, pageIndex: 0), PageRef(url: b, pageIndex: 0)], to: out)
        }
        #expect(try Data(contentsOf: out) == Data("alt".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(leftovers == ["A.pdf", "Auswahl.pdf"])
    }

    @Test(.enabled(if: getuid() != 0, "root ignores directory permissions"))
    func failedWriteStageKeepsExistingFile() throws {
        let locked = dir.appendingPathComponent("schreibgeschuetzt", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let out = locked.appendingPathComponent("Auswahl.pdf")
        try Data("alt".utf8).write(to: out)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let error = #expect(throws: OutputError.self) {
            try Merger().write([PageRef(url: a, pageIndex: 0)], to: out)
        }
        guard case .writeFailed(let url, let reason) = error else { Issue.record("expected writeFailed, got \(String(describing: error))"); return }
        #expect(url == out)
        #expect(!reason.isEmpty)
        #expect(try Data(contentsOf: out) == Data("alt".utf8))
    }

    @Test func replacingKeepsPermissionsAndExtendedAttributes() throws {
        // Finder tags live in an extended attribute; the save dialog's "Replace" must not strip them.
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Data("alt".utf8).write(to: out)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        let value = Array("rot".utf8)
        try #require(setxattr(out.path, "local.pdfsucher.test", value, value.count, 0, 0) == 0)

        try Merger().write([PageRef(url: a, pageIndex: 0)], to: out)

        #expect(texts(try #require(PDFDocument(url: out))) == ["Alpha null"])
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = getxattr(out.path, "local.pdfsucher.test", &buffer, buffer.count, 0, 0)
        #expect(n == value.count && Array(buffer.prefix(max(n, 0))) == value)
    }

    /// A copy of A.pdf whose page 0 carries an internal link to page 2.
    private func pdfWithLink() throws -> URL {
        let doc = try #require(PDFDocument(url: a))
        let link = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 100, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: try #require(doc.page(at: 2)), at: CGPoint(x: 0, y: 800))
        try #require(doc.page(at: 0)).addAnnotation(link)
        let url = dir.appendingPathComponent("Link.pdf")
        try #require(doc.write(to: url))
        return url
    }

    private func linkTargets(_ doc: PDFDocument, onPage i: Int) -> [Int?] {
        doc.page(at: i)!.annotations.filter { $0.type == "Link" }.map { link in
            let dest = (link.action as? PDFActionGoTo)?.destination ?? link.destination
            return dest?.page.map { doc.index(for: $0) }
        }
    }

    @Test func internalLinksFollowTheirTargetIntoTheMerge() throws {
        let src = try pdfWithLink()
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Merger().write([PageRef(url: b, pageIndex: 0), PageRef(url: src, pageIndex: 0), PageRef(url: src, pageIndex: 2)], to: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(linkTargets(doc, onPage: 1) == [2])
    }

    @Test func internalLinksToPagesNotMergedAreRemoved() throws {
        // Otherwise the link silently jumps to page 1 of the merged PDF.
        let src = try pdfWithLink()
        let doc = try Merger().makeDocument([PageRef(url: src, pageIndex: 0), PageRef(url: b, pageIndex: 0)])
        #expect(linkTargets(doc, onPage: 0).isEmpty)
        #expect(texts(doc) == ["Alpha null", "Beta null"])
    }
}

@Suite("Printer")
@MainActor
struct PrinterTests {
    @Test func printOperationBuilds() throws {
        let dir = try PDFFixtures.tempDirectory()
        let a = dir.appendingPathComponent("A.pdf")
        try PDFFixtures.makePDF(at: a, pages: ["eins", "zwei", "drei"])
        let op = try Printer.printOperation(for: [PageRef(url: a, pageIndex: 2), PageRef(url: a, pageIndex: 0)])
        let view = try #require(op.view)
        var range = NSRange()
        #expect(view.knowsPageRange(&range))
        #expect(range.length == 2)
        #expect(op.showsPrintPanel)
    }

    @Test func printOperationPrintsSelectedPagesInOrder() throws {
        let dir = try PDFFixtures.tempDirectory()
        let a = dir.appendingPathComponent("A.pdf")
        try PDFFixtures.makePDF(at: a, pages: ["eins", "zwei", "drei"])
        let op = try Printer.printOperation(for: [PageRef(url: a, pageIndex: 2), PageRef(url: a, pageIndex: 0)])
        let out = dir.appendingPathComponent("gedruckt.pdf")
        op.printInfo.jobDisposition = .save
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        #expect(op.run())
        let printed = try #require(PDFDocument(url: out))
        let texts = (0..<printed.pageCount).map { printed.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(texts == ["drei", "eins"])
    }

    @Test func printReportsMissingFile() throws {
        let missing = URL(fileURLWithPath: "/nicht/vorhanden.pdf")
        #expect(throws: OutputError.cannotOpen(missing)) {
            try Printer.printOperation(for: [PageRef(url: missing, pageIndex: 0)])
        }
    }

    @Test func printEmptyThrows() {
        #expect(throws: OutputError.emptySelection) { try Printer.printOperation(for: []) }
    }
}
