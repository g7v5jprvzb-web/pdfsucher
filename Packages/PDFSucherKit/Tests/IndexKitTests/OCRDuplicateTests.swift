import CoreGraphics
import Foundation
@testable import IndexKit
import Testing
import TestSupport
import UniformTypeIdentifiers

/// 1.5.0: identical images and scanned PDFs are recognized once; copies take over text and word boxes, within a run
/// and from earlier runs (content hash in the index).
@Suite("OCR duplicates")
struct OCRDuplicateTests {
    struct Env {
        let base: URL, root: URL
        let store: IndexStore
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    }

    func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory()
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Env(base: base, root: root, store: try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root))
    }

    func image(_ env: Env, _ name: String, _ text: String) throws {
        try OCRFixtures.write(try OCRFixtures.textImage([text], size: CGSize(width: 200, height: 100), fontSize: 20).image,
                              to: env.url(name), type: .png)
    }

    @Test func copiesInOneRunAreRecognizedOnce() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try image(env, "a.png", "Rechnung")
        try FileManager.default.copyItem(at: env.url("a.png"), to: env.url("b.png"))
        try FileManager.default.createDirectory(at: env.url("Unter"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: env.url("a.png"), to: env.url("Unter/c.png"))
        try image(env, "anders.png", "Quittung")
        let stub = StubOCR()
        let report = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        #expect(stub.calls.count == 2, "\(stub.calls)")
        #expect(report.ocr.recognized == 4)
        let lead = try #require(try env.store.ocrPage(relativePath: "a.png", pageIndex: 0))
        for copy in ["b.png", "Unter/c.png"] {
            let page = try #require(try env.store.ocrPage(relativePath: copy, pageIndex: 0))
            #expect(page.text == lead.text)
            #expect(page.words == lead.words && !page.words.isEmpty)
        }
        #expect(try env.store.pendingOCRJobs().isEmpty)
        #expect(try env.store.documents().allSatisfy { $0.status == .ok })
    }

    @Test func aLaterCopyTakesOverFromTheIndex() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try image(env, "a.png", "Rechnung")
        _ = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { _ in }
        try FileManager.default.copyItem(at: env.url("a.png"), to: env.url("neu.png"))
        let stub = StubOCR()
        _ = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        #expect(stub.calls.isEmpty, "\(stub.calls)")
        #expect(try env.store.ocrPage(relativePath: "neu.png", pageIndex: 0)?.text
                == (try env.store.ocrPage(relativePath: "a.png", pageIndex: 0)?.text))
    }

    @Test func scannedPDFCopiesAreRecognizedOnce() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try OCRFixtures.makeScanPDF(at: env.url("scan.pdf"), images: [try OCRFixtures.textImage(["eins"]).image,
                                                                       try OCRFixtures.textImage(["zwei"]).image])
        try FileManager.default.copyItem(at: env.url("scan.pdf"), to: env.url("kopie.pdf"))
        let stub = StubOCR()
        _ = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        #expect(stub.calls.count == 2, "\(stub.calls)")
        for page in 0..<2 {
            #expect(try env.store.ocrPage(relativePath: "kopie.pdf", pageIndex: page)?.text
                    == (try env.store.ocrPage(relativePath: "scan.pdf", pageIndex: page)?.text))
        }
    }

    @Test func aChangedFileIsRecognizedAgain() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try image(env, "a.png", "Rechnung")
        try FileManager.default.copyItem(at: env.url("a.png"), to: env.url("b.png"))
        _ = try await Indexer(root: env.root, store: env.store, ocr: StubOCR()).update { _ in }
        try FileManager.default.removeItem(at: env.url("b.png"))
        try image(env, "b.png", "Etwas ganz anderes mit mehr Text")
        let stub = StubOCR()
        _ = try await Indexer(root: env.root, store: env.store, ocr: stub).update { _ in }
        #expect(stub.calls == ["b.png#0"])
    }

    @Test func runLogsCopiesAndHashing() async throws {
        let env = try makeEnv(); defer { env.cleanup() }
        try image(env, "a.png", "Rechnung")
        try FileManager.default.copyItem(at: env.url("a.png"), to: env.url("b.png"))
        let logs = env.base.appendingPathComponent("Logs", isDirectory: true)
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        _ = try await Indexer(root: env.root, store: env.store, ocr: StubOCR(), metrics: metrics).update { _ in }
        metrics.flush()
        let raw = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        let events = raw.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let end = try #require(events.first { $0["event"] as? String == "phase_end" && $0["phase"] as? String == "ocr" })
        #expect(end["copied"] as? Int == 1)
        #expect(end["hashed"] as? Int == 2)
        #expect(end["hash_ms"] as? NSNumber != nil)
        #expect(events.filter { $0["event"] as? String == "ocr_page" }.compactMap { $0["result"] as? String }.sorted() == ["copied", "ok"])
    }
}
