import AppKit
import Compression
import Foundation
import IndexKit
import OutputKit
import PDFKit
import Testing
import TestSupport
@testable import ViewerUI

/// 1.4.4: a PDF whose pages take seconds to find (flat page tree in one compressed object stream) froze the main
/// thread for 20 s when the large preview handed it to PDFView. It opens as a one-page document now.
@Suite("Slow PDF in the large preview", .serialized)
@MainActor
struct SlowPDFPreviewTests {
    @Test func slowPDFOpensAsOnePageAndBlocksTheMainThreadBriefly() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("langsam.pdf")
        try Self.writeSlowPDF(to: url, pages: 2_000)
        let logs = dir.appendingPathComponent("Logs", isDirectory: true)
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let clock = ContinuousClock()

        // Before: PDFView with the whole document blocks the main thread for seconds.
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let whole = try #require(PDFDocument(url: url))
        let before = clock.measure { view.document = whole }
        #expect(before > .milliseconds(250), "the test PDF no longer reproduces the slow page tree: \(before)")

        let ref = PageRef(url: url, pageIndex: 1_234)
        guard case .ready(let document) = await DetailDocument.load(ref, metrics: metrics) else {
            Issue.record("not loaded"); return
        }
        #expect(document.singlePage == 1_234)
        #expect(document.pdf.pageCount == 1)
        #expect(document.documentPageIndex(for: ref) == 0)
        #expect(document.tracker != nil)
        let page = try #require(document.pdf.page(at: 0))
        #expect(page.string?.contains("Seite mit Text") == true)
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
        let after = clock.measure { PDFView(frame: view.frame).document = document.pdf }
        #expect(after < .milliseconds(250), "main thread blocked \(after)")

        // The same page again is reused; another page of the file is opened for that page.
        guard case .ready(let again) = await DetailDocument.load(ref, reusing: document, metrics: metrics) else { return }
        #expect(again == document)
        guard case .ready(let other) = await DetailDocument.load(PageRef(url: url, pageIndex: 5), reusing: document, metrics: metrics)
        else { return }
        #expect(other.singlePage == 5 && other != document)

        metrics.flush()
        let raw = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!raw.contains("langsam"))
        let opens = raw.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["event"] as? String == "preview_open" }
        #expect(opens.count == 2)
        #expect(opens.first?["file"] as? String == IndexMetrics.hash(url))
        #expect(opens.first?["pages"] as? Int == 2_000)
        #expect(opens.first?["way"] as? String == "single_page")
    }

    @Test func normalPDFStaysWhole() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("normal.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["eins", "zwei", "drei"])
        let metrics = IndexMetrics(directory: dir.appendingPathComponent("Logs", isDirectory: true))
        guard case .ready(let document) = await DetailDocument.load(PageRef(url: url, pageIndex: 1), metrics: metrics) else {
            Issue.record("not loaded"); return
        }
        #expect(document.singlePage == nil)
        #expect(document.pdf.pageCount == 3)
        #expect(document.pdf.page(at: 1)?.string?.contains("zwei") == true)
    }

    /// `pages` pages in a flat page tree; catalog, page tree and pages sit in one compressed object stream, padded
    /// so that CoreGraphics unpacks a lot to reach each page (like the file that hung on the other Mac).
    static func writeSlowPDF(to url: URL, pages: Int, padding: Int = 2_000) throws {
        let kids = (0..<pages).map { "\(5 + $0) 0 R" }.joined(separator: " ")
        var inside: [(Int, String)] = [(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                                       (2, "<< /Type /Pages /Count \(pages) /Kids [\(kids)] >>")]
        let pad = String(repeating: "x", count: padding)
        for i in 0..<pages {
            inside.append((5 + i, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> "
                           + "/Contents 4 0 R /Pad (\(pad)) >>"))
        }
        var body = "", offsets: [String] = []
        for (number, object) in inside {
            offsets.append("\(number) \(body.utf8.count)")
            body += object + "\n"
        }
        let header = offsets.joined(separator: " ") + "\n"
        let stream = try zlib(Data((header + body).utf8))
        let content = "BT /F1 24 Tf 72 720 Td (Seite mit Text) Tj ET"
        let objectStream = 5 + pages, xrefNumber = objectStream + 1
        var out = Data("%PDF-1.5\n%\u{e2}\u{e3}\n".utf8)
        var positions: [Int: Int] = [:]
        func add(_ number: Int, _ head: String, stream: Data? = nil) {
            positions[number] = out.count
            out.append(Data("\(number) 0 obj\n\(head)".utf8))
            if let stream { out.append(Data("\nstream\n".utf8)); out.append(stream); out.append(Data("\nendstream".utf8)) }
            out.append(Data("\nendobj\n".utf8))
        }
        add(3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        add(4, "<< /Length \(content.utf8.count) >>", stream: Data(content.utf8))
        add(objectStream, "<< /Type /ObjStm /N \(inside.count) /First \(header.utf8.count) /Filter /FlateDecode /Length \(stream.count) >>",
            stream: stream)
        let index = Dictionary(uniqueKeysWithValues: inside.enumerated().map { ($1.0, $0) })
        positions[xrefNumber] = out.count
        var rows = Data()
        func row(_ type: UInt8, _ a: Int, _ b: Int) {
            rows.append(type)
            for v in [a, b] { withUnsafeBytes(of: UInt32(v).bigEndian) { rows.append(contentsOf: $0) } }
        }
        for n in 0...xrefNumber {
            if n == 0 { row(0, 0, 65_535) } else if let i = index[n] { row(2, objectStream, i) } else { row(1, positions[n]!, 0) }
        }
        let xref = try zlib(rows)
        let xrefStart = out.count
        out.append(Data("\(xrefNumber) 0 obj\n<< /Type /XRef /Size \(xrefNumber + 1) /W [1 4 4] /Root 1 0 R /Filter /FlateDecode /Length \(xref.count) >>\nstream\n".utf8))
        out.append(xref)
        out.append(Data("\nendstream\nendobj\nstartxref\n\(xrefStart)\n%%EOF\n".utf8))
        try out.write(to: url)
    }

    /// zlib stream (header, raw deflate, Adler-32), as /FlateDecode wants it.
    private static func zlib(_ data: Data) throws -> Data {
        let raw = try (data as NSData).compressed(using: .zlib) as Data      // raw deflate (RFC 1951)
        var adler: (UInt32, UInt32) = (1, 0)
        for byte in data { adler.0 = (adler.0 + UInt32(byte)) % 65_521; adler.1 = (adler.1 + adler.0) % 65_521 }
        var out = Data([0x78, 0x9C])
        out.append(raw)
        withUnsafeBytes(of: ((adler.1 << 16) | adler.0).bigEndian) { out.append(contentsOf: $0) }
        return out
    }
}
