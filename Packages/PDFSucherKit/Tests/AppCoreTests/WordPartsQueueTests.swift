import Foundation
import IndexKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// 1.3.12: the Wortteil-Index step runs after phase 1 of every folder and before folder layout and recognition; new
/// phase-1 work pre-empts it; the status and the search summary say so.
@MainActor @Suite("Wortteil-Index in the queue", .timeLimit(.minutes(1)))
struct WordPartsQueueTests {
    let base: URL

    init() throws { base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath() }

    func folders(_ names: [String], log: StringLog) throws -> (urls: [URL], indexes: [String: FakeIndex]) {
        var indexes: [String: FakeIndex] = [:]
        let urls = try names.map { name in
            let url = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let index = FakeIndex()
            index.name = name
            index.ocrLog = log
            index.layoutLog = log
            index.wordPartsLog = log
            indexes[name] = index
            return url
        }
        return (urls, indexes)
    }

    func model(_ indexes: [String: FakeIndex]) -> AppModel {
        AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "WordParts-\(UUID().uuidString)")!,
                 environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                 openIndex: { root in
                     guard let index = indexes[root.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
                     return index
                 })
    }

    func position(_ entry: String, in log: StringLog) -> Int { log.entries.firstIndex(of: entry) ?? .max }

    @Test func runsAfterEveryPhaseOneAndBeforeLayoutAndRecognition() async throws {
        let log = StringLog()
        let (urls, indexes) = try folders(["eins", "zwei"], log: log)
        let m = model(indexes)
        await m.add(urls)
        await m.waitUntilIdle()
        let lastUpdate = max(position("eins:update-end", in: log), position("zwei:update-end", in: log))
        let wordParts = [position("eins:wordparts-end", in: log), position("zwei:wordparts-end", in: log)]
        #expect(wordParts.allSatisfy { $0 != .max && $0 > lastUpdate }, "\(log.entries)")
        let later = log.entries.indices.filter { log.entries[$0].hasSuffix("layout-start") || log.entries[$0].hasSuffix("ocr-start") }
        #expect(!later.isEmpty)
        #expect(later.allSatisfy { $0 > wordParts.max()! }, "\(log.entries)")
    }

    @Test func newPhaseOneWorkPreemptsItAndItResumes() async throws {
        let log = StringLog()
        let (urls, indexes) = try folders(["eins", "zwei"], log: log)
        let m = model(indexes)
        indexes["eins"]!.holdWordParts = true
        await m.add([urls[0]])
        while !log.entries.contains("eins:wordparts-start") { try await Task.sleep(for: .milliseconds(2)) }
        if case .preparingWordParts = m.indexStatus {} else { Issue.record("status \(m.indexStatus)") }
        await m.add([urls[1]])
        while !log.entries.contains("eins:wordparts-cancelled") { try await Task.sleep(for: .milliseconds(2)) }
        indexes["eins"]!.holdWordParts = false
        await m.waitUntilIdle()
        let cancelled = position("eins:wordparts-cancelled", in: log)
        #expect(position("zwei:update-start", in: log) > cancelled)
        #expect(log.entries.lastIndex(of: "eins:wordparts-end").map { $0 > position("zwei:update-end", in: log) } == true, "\(log.entries)")
    }

    @Test func aWordPartSearchSaysItMayBeSlowerWhileTheIndexIsBuilt() async throws {
        let log = StringLog()
        let (urls, indexes) = try folders(["eins"], log: log)
        let index = indexes["eins"]!
        index.hits = [DocumentHit(url: urls[0].appendingPathComponent("a.pdf"), relativePath: "a.pdf", modifiedAt: .distantPast,
                                  pageHits: [PageHit(pageIndex: 0, matchCount: 1)], totalMatches: 1, relevance: 1, sourceRoot: urls[0], pageCount: 1)]
        index.holdWordParts = true
        let m = model(indexes)
        await m.add(urls)
        while !log.entries.contains("eins:wordparts-start") { try await Task.sleep(for: .milliseconds(2)) }
        m.queryText = "*trag*"
        while !m.summary.hasPrefix("Gefunden") { try await Task.sleep(for: .milliseconds(2)) }
        #expect(m.summary.hasSuffix(ViewerText.wordPartsSlow))
        m.queryText = "Vertrag"
        while m.summary.hasSuffix(ViewerText.wordPartsSlow) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(m.summary.hasPrefix("Gefunden"), "a word search does not use the word-parts index")
        m.queryText = "*trag*"
        while !m.summary.hasSuffix(ViewerText.wordPartsSlow) { try await Task.sleep(for: .milliseconds(2)) }
        index.holdWordParts = false
        await m.waitUntilIdle()
        #expect(m.summary.hasPrefix("Gefunden"))
        #expect(!m.summary.contains(ViewerText.wordPartsSlow), "the hint goes when the index is complete")
    }

    @Test func statusText() {
        #expect(ViewerText.indexStatus(.preparingWordParts(folder: 1, folders: 1, done: 2, total: 5)) == "Wortteil-Suche wird vorbereitet … (40 %)")
        #expect(ViewerText.indexStatus(.preparingWordParts(folder: 2, folders: 3, done: 0, total: 0)) == "Ordner 2/3: Wortteil-Suche wird vorbereitet … (0 %)")
    }
}
