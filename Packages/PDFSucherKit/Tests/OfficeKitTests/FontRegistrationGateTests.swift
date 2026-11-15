import Dispatch
import Foundation
import OOXMLKit
import Synchronization
import Testing
import TestSupport
@testable import OfficeKit

/// A registration that blocks until released (a macOS prompt nobody answers), counting its runs.
private final class BlockingRegistration: Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let runs = Mutex(0)
    var count: Int { runs.withLock { $0 } }
    /// The run count once the started registration had time to begin (its thread may be slow to start under load).
    func settledCount() -> Int {
        let deadline = Date().addingTimeInterval(5)
        while count == 0, Date() < deadline { usleep(5_000) }
        usleep(50_000)
        return count
    }
    func run() { runs.withLock { $0 += 1 }; release.wait() }
    func finish() { release.signal() }
}

/// 1.3.2: Word layout waits for Office's font registration at most a few seconds (denied or unanswered prompt).
@Suite("Font registration gate")
struct FontRegistrationGateTests {
    @Test func finishedRegistrationReturnsAtOnce() {
        let runs = Mutex(0)
        let gate = FontRegistrationGate(timeout: .seconds(5)) { runs.withLock { $0 += 1 } }
        #expect(gate.wait())
        #expect(gate.wait())
        #expect(runs.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1))) func blockedRegistrationTimesOutOnceThenNeverWaitsAgain() {
        let registration = BlockingRegistration()
        defer { registration.finish() }
        let gate = FontRegistrationGate(timeout: .milliseconds(300)) { registration.run() }
        let clock = ContinuousClock()
        let first = clock.measure { #expect(gate.wait() == false) }
        #expect(first >= .milliseconds(250) && first < .seconds(3))
        let second = clock.measure { #expect(gate.wait() == false) }
        #expect(second < .milliseconds(100))
        #expect(registration.settledCount() == 1)
    }

    /// Callers arriving together wait for one deadline, not one timeout each after another.
    @Test(.timeLimit(.minutes(1))) func concurrentFirstCallersShareOneDeadline() {
        let registration = BlockingRegistration()
        defer { registration.finish() }
        let gate = FontRegistrationGate(timeout: .milliseconds(300)) { registration.run() }
        let waits = Mutex<[Duration]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let waited = ContinuousClock().measure { _ = gate.wait() }
            waits.withLock { $0.append(waited) }
        }
        #expect(waits.withLock { $0 }.allSatisfy { $0 < .seconds(1) })
        #expect(registration.settledCount() == 1)
    }

    /// A Word document is laid out after the timeout although the registration never ends (prompt denied or
    /// unanswered), and the next one does not wait again.
    @Test(.timeLimit(.minutes(1))) func wordLayoutProceedsAfterTheTimeout() throws {
        #expect(FontResolver.officeFontRoots == .none)      // tests never read the real Office folders
        FontResolver.prewarm()            // the registration is done, so TextKit never runs beside it here
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Die Kündigungsfrist beträgt drei Monate"], name: "Vertrag.docx", in: dir)
        let registration = BlockingRegistration()
        defer { registration.finish() }
        let gate = FontRegistrationGate(timeout: .milliseconds(300)) { registration.run() }
        let clock = ContinuousClock()
        var document: TextKitWordDocument?
        let first = try clock.measure { document = try TextKitWordDocument(url: docx, maxPages: 10, fontGate: gate, fonts: .start) }
        // Upper bound generous: the layout itself may wait for `textKit` while other suites lay out Word documents.
        #expect(first >= .milliseconds(250) && first < .seconds(30))
        #expect(document?.pageCount == 1)
        // The next layout does not wait at the gate again (only the gate is timed: `textKit` may be busy elsewhere).
        let secondPass = clock.measure { #expect(gate.pass(.start) == false) }
        #expect(secondPass < .milliseconds(100))
        #expect(try TextKitWordDocument(url: docx, maxPages: 10, fontGate: gate, fonts: .start).pageCount == 1)
        #expect(registration.settledCount() == 1)
    }

    /// The registration starts although GCD's global queues admit no new work: their threads all block (as when every
    /// cooperative thread waits in `wait()`, which starved the old `DispatchQueue.global` registration for up to 4.9 s).
    /// The blocked work is released at once afterwards (the global queues of this test process stall that briefly).
    @Test(.timeLimit(.minutes(1))) func registrationStartsWhileGlobalQueuesAreSaturated() {
        let release = DispatchSemaphore(value: 0)
        let blockers = max(256, ProcessInfo.processInfo.activeProcessorCount * 16)   // above the constrained-thread limit
        let started = Mutex(0)
        // At every QoS a caller may have, so threads freed meanwhile go to blocked work queued before the registration.
        let classes: [DispatchQoS.QoSClass] = [.userInteractive, .userInitiated, .default, .utility, .background]
        for i in 0..<blockers {
            DispatchQueue.global(qos: classes[i % classes.count]).async {
                started.withLock { $0 += 1 }
                release.wait()
            }
        }
        defer { for _ in 0..<blockers { release.signal() } }
        // Until GCD stops adding threads for them (the pool is full).
        var last = -1, stableSince = Date(), giveUp = Date().addingTimeInterval(3)
        while Date() < giveUp {
            let now = started.withLock { $0 }
            if now != last { last = now; stableSince = Date() } else if Date().timeIntervalSince(stableSince) > 0.2 { break }
            usleep(10_000)
        }
        let runs = Mutex(0)
        let gate = FontRegistrationGate(timeout: .seconds(2)) { runs.withLock { $0 += 1 } }
        let waited = ContinuousClock().measure { #expect(gate.wait(), "registration starved behind the blocked GCD threads") }
        #expect(waited < .seconds(1))
        #expect(runs.withLock { $0 } == 1)
    }

    /// 3 s: more than OOXMLKit's 2 s limit for the cloud font cache plus the DFonts registration.
    @Test func sharedGateWaitsAtMostThreeSeconds() {
        #expect(FontRegistrationGate.sharedTimeout == DispatchTimeInterval.seconds(3))
    }

    // MARK: Join only (display paths)

    @Test func joinBeforeAnyStartReturnsAtOnceWithoutRegistering() {
        let runs = Mutex(0)
        let gate = FontRegistrationGate(timeout: .seconds(5)) { runs.withLock { $0 += 1 } }
        let waited = ContinuousClock().measure { #expect(gate.join() == false) }
        #expect(waited < .milliseconds(100))
        usleep(50_000)
        #expect(runs.withLock { $0 } == 0)
    }

    @Test(.timeLimit(.minutes(1))) func joinWaitsForAStartedRegistrationUpToTheDeadline() {
        let registration = BlockingRegistration()
        defer { registration.finish() }
        let gate = FontRegistrationGate(timeout: .milliseconds(300)) { registration.run() }
        gate.start()
        let waited = ContinuousClock().measure { #expect(gate.join() == false) }
        #expect(waited >= .milliseconds(200) && waited < .seconds(3))
        #expect(registration.settledCount() == 1)
    }

    @Test func joinReturnsTrueOnceTheRegistrationIsDone() {
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        #expect(gate.wait())
        #expect(gate.join())
    }

    /// Tiles, previews, output and page counts open Word documents through `cached(url:)`: they only join, so a
    /// display path never starts the registration (and never brings up the macOS prompt).
    @Test func displayPathOnlyJoins() throws {
        #expect(FontResolver.officeFontRoots == .none)      // tests never read the real Office folders
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Anzeige"], name: "Anzeige.docx", in: dir)
        let runs = Mutex(0)
        let gate = FontRegistrationGate(timeout: .seconds(5)) { runs.withLock { $0 += 1 } }
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 2)
        _ = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate)
        usleep(50_000)
        #expect(runs.withLock { $0 } == 0)
        // The layout path starts it.
        let other = try OfficeFixtures.docx(paragraphs: ["Layout"], name: "Layout.docx", in: dir)
        _ = try TextKitWordDocument.cached(url: other, in: cache, fontGate: gate, fonts: .start)
        #expect(runs.withLock { $0 } == 1)
    }

    /// Review of 1.3.2: a document a display path laid out before the registration (substitute fonts) is laid out
    /// once more when Office's fonts are there – for the layout phase (index text, word boxes) and for displays.
    @Test func documentLaidOutBeforeTheFontsIsLaidOutAgainAfterThem() throws {
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Vorher"], name: "Vorher.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .seconds(5)) {}
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 2)
        let early = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate)
        #expect(!gate.isDone)
        #expect(try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate) === early, "no fonts yet: the same")
        let layout = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate, fonts: .start)
        #expect(gate.isDone)
        #expect(layout !== early, "the layout phase does not reuse a document set with substitute fonts")
        #expect(try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate) === layout, "displays get the new one")
    }

    /// A registration that missed the deadline is not done: documents are not laid out again and again.
    @Test(.timeLimit(.minutes(1))) func timedOutRegistrationKeepsTheDocuments() throws {
        let registration = BlockingRegistration()
        defer { registration.finish() }
        let dir = try PDFFixtures.tempDirectory()
        let docx = try OfficeFixtures.docx(paragraphs: ["Zeitlimit"], name: "Zeitlimit.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .milliseconds(200)) { registration.run() }
        let cache = DocumentLRU<TextKitWordDocument.CacheKey, TextKitWordDocument>(capacity: 2)
        let first = try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate, fonts: .start)
        #expect(!gate.isDone)
        #expect(try TextKitWordDocument.cached(url: docx, in: cache, fontGate: gate, fonts: .start) === first)
    }
}
