import Dispatch
import Foundation
import IndexKit
import Synchronization
import Testing
import TestSupport
@testable import OfficeKit

/// A fake registration (no fonts at all) that blocks until released: a macOS prompt nobody answers yet.
private final class HeldRegistration: Sendable {
    private let release = DispatchSemaphore(value: 0)
    func run() { release.wait() }
    func finish() { release.signal() }
}

/// 1.3.2 (fonts-start e/d): a Word document laid out with substitute fonts (the gate's deadline passed, or a display
/// path laid it out before the registration) is marked as such in the index, and laid out again once the
/// registration is done – so word boxes and tiles drawn with Office's fonts always match. Tile keys of Word pages
/// carry the font state, so a tile drawn with substitute fonts is not reused after the registration.
@Suite("Word font state")
struct WordFontStateTests {
    @Test(.timeLimit(.minutes(1))) func wordLaidOutWithSubstituteFontsIsMarkedAndStaleOnceTheFontsAreThere() async throws {
        let registration = HeldRegistration()
        defer { registration.finish() }
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Ersatzschrift"], name: "Ersatz.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .milliseconds(200)) { registration.run() }
        let source = TextKitWordSource(fontGate: gate)
        #expect(source.staleRenderers(for: .word).isEmpty, "nothing registered yet: nothing is stale")

        let early = try await source.layout(of: docx, kind: .word)
        #expect(early.renderer == TextKitWordSource.substituteRenderer, "deadline passed: substitute fonts")
        #expect(early.layoutVersion == 1)
        #expect(source.staleRenderers(for: .word).isEmpty, "a registration past its deadline is not done")

        registration.finish()
        let deadline = Date().addingTimeInterval(10)
        while !gate.isDone, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.isDone)
        #expect(source.staleRenderers(for: .word) == [TextKitWordSource.substituteRenderer])
        #expect(source.staleRenderers(for: .powerpoint).isEmpty)

        let late = try await source.layout(of: docx, kind: .word)
        #expect(late.renderer == "textkit", "laid out again with the fonts")
        #expect(source.renderer(for: .word).name == "textkit" && source.renderer(for: .word).version == 1,
                "the expected renderer stays: no relayout of every Word document")
    }

    @Test func documentRecordsWhetherTheFontsWereThere() throws {
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Schrift"], name: "Schrift.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 2)
        let joined = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate)
        #expect(!joined.laidOutWithOfficeFonts)
        let started = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate, fonts: .start)
        #expect(started.laidOutWithOfficeFonts)
    }

    @Test func officeLayoutSourceForwardsStaleWordRenderers() async throws {
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        let layout = OfficeLayoutSource(word: TextKitWordSource(fontGate: gate))
        #expect(layout.staleRenderers(for: .word).isEmpty)
        gate.wait()
        #expect(layout.staleRenderers(for: .word) == [TextKitWordSource.substituteRenderer])
        #expect(layout.staleRenderers(for: .pdf).isEmpty)
    }

    /// The renderer marked for substitute fonts still counts as the simplified Word renderer („vereinfacht“).
    @Test func substituteRendererIsStillSimplified() {
        let doc = StoredDocument(id: 1, relativePath: "a.docx", fileSize: 1, modifiedAt: Date(), pageCount: 1, status: .ok,
                                 kind: .word, renderer: TextKitWordSource.substituteRenderer, layoutVersion: 1)
        #expect(doc.isSimplified)
    }

    /// Tile keys (`contentVersion`) of Word pages name the font state: a tile drawn with substitute fonts is not
    /// reused, in memory or on disk, once Office's fonts are registered.
    @Test func wordContentVersionNamesTheFontState() throws {
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Kachel"], name: "Kachel.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        let cache = SlideCache(root: dir.appendingPathComponent("Slides", isDirectory: true))
        let pages = OfficePages(cache: cache, renderers: OfficeLayoutSource(), fontGate: gate)
        let before = pages.contentVersion(docx)
        #expect(before == "textkit:1")
        gate.wait()
        let after = pages.contentVersion(docx)
        #expect(after == "textkit:1+fonts")
    }

    // MARK: Cloud fonts missed (review of 229d93a)

    /// The registration finished inside its deadline but gave up on Office's cloud fonts (prompt still open after
    /// 2 s): the fonts are not complete. Word is marked substitute, nothing is stale (no relayout loop in this
    /// process), tile keys carry no `+fonts`.
    @Test func doneButCloudFontsMissedIsNotComplete() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Wolke"], name: "Wolke.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .seconds(5), register: {}, complete: { false })
        #expect(gate.wait(), "the registration itself finished in time")
        #expect(gate.isDone)
        #expect(!gate.isComplete)
        let source = TextKitWordSource(fontGate: gate)
        let result = try await source.layout(of: docx, kind: .word)
        #expect(result.renderer == TextKitWordSource.substituteRenderer)
        #expect(source.staleRenderers(for: .word).isEmpty)
        let pages = OfficePages(cache: SlideCache(root: dir.appendingPathComponent("Slides", isDirectory: true)),
                                renderers: OfficeLayoutSource(), fontGate: gate)
        #expect(pages.contentVersion(docx) == "textkit:1")
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 2)
        let doc = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate, fonts: .start)
        #expect(!doc.laidOutWithOfficeFonts)
    }

    /// The document cache key (35f8f55) follows the same predicate: a document laid out while the fonts were not
    /// complete is laid out again once they are.
    @Test func cacheKeyFollowsCompleteness() throws {
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Schlüssel"], name: "Schluessel.docx", in: dir)
        let complete = Mutex(false)
        let gate = FontRegistrationGate(timeout: .seconds(5), register: {}, complete: { complete.withLock { $0 } })
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 2)
        let first = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate, fonts: .start)
        #expect(try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate) === first)
        complete.withLock { $0 = true }
        let second = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate)
        #expect(second !== first)
        #expect(second.laidOutWithOfficeFonts)
    }

    /// A registration that missed the waiter's deadline but finishes later reports its completion (`notifyWhenDone`).
    @Test(.timeLimit(.minutes(1))) func lateCompletionIsReported() async throws {
        let registration = HeldRegistration()
        let gate = FontRegistrationGate(timeout: .milliseconds(100)) { registration.run() }
        let notified = Mutex(false)
        gate.notifyWhenDone { notified.withLock { $0 = true } }          // not started: never
        #expect(!gate.wait())
        gate.notifyWhenDone { notified.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!notified.withLock { $0 })
        registration.finish()
        let deadline = Date().addingTimeInterval(10)
        while !notified.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(notified.withLock { $0 })
        #expect(gate.isComplete)
    }
}
