// WordLayoutFontStressTests.swift — 1.3.2: Word layout (TextKit) beside Office font registrations.
// A registration while TextKit lays out a text storage on another thread raised „attempted layout while textStorage is
// editing“ (2 of 5 suite runs before ae4c89e). Here many Word documents are laid out, queried and drawn in parallel
// while real registrations (`FontResolver.registerFonts(in:)`, the path OfficeFonts uses) run beside them, directly
// and through a `FontRegistrationGate` that layouts start or join. Must neither crash nor deadlock. The fonts are
// macOS's Andale Mono renamed to unique families in temp folders; the real Office folders are never read.
// The crash is rare: with the font gate removed from TextKitWordDocument the test process crashed with that exception
// in 1 of 13 runs of 60 rounds (2026-11-13); with the gate 0 of 5 such runs (and every suite run). So a pass does
// not prove the gate; a crash or a time-out here is a real finding.
import AppKit
import CoreText
import Dispatch
import Foundation
@testable import OOXMLKit
import Synchronization
import Testing
import TestSupport
@testable import OfficeKit

/// Renamed copies of Andale Mono (same name length, so no table offsets change), one unique family per file.
private enum StressFonts {
    static let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Andale Mono.ttf")
    private static let counter = Mutex(0)

    /// 6 letters, unique in this process, unlikely to be installed („Wq“ + 4 letters).
    static func uniqueTag() -> String {
        let n = counter.withLock { c -> Int in c += 1; return c } + Int.random(in: 0..<(26 * 26 * 26 * 26 / 2))
        var letters = "", value = n
        for _ in 0..<4 { letters.append(Character(UnicodeScalar(UInt8(97 + value % 26)))); value /= 26 }
        return "Wq" + letters
    }

    /// A new folder with `count` font files of new families.
    static func folder(count: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wordstress-fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try Data(contentsOf: source)
        for i in 0..<count {
            try renamed(original, to: uniqueTag()).write(to: root.appendingPathComponent("f\(i).ttf"))
        }
        return root
    }

    /// Unregisters the folder's fonts as a font change (`exclusiveFontChange`, like a registration: no layout runs
    /// meanwhile, and the hold lasts until AppKit delivered the font-set changes of the successful unregister calls)
    /// and removes it.
    static func remove(_ root: URL) {
        FontResolver.fontGate.exclusiveFontChange {
            OfficeFonts.fontFiles(in: [root]).filter { CTFontManagerUnregisterFontsForURL($0 as CFURL, .process, nil) }.count
        }
        FontResolver.fontsChanged()
        try? FileManager.default.removeItem(at: root)
    }

    private static func renamed(_ data: Data, to tag: String) -> Data {
        var bytes = [UInt8](data)
        func replace(_ from: [UInt8], _ to: [UInt8]) {
            var i = 0
            while i + from.count <= bytes.count {
                if Array(bytes[i..<(i + from.count)]) == from {
                    bytes.replaceSubrange(i..<(i + from.count), with: to)
                    i += from.count
                } else { i += 1 }
            }
        }
        replace(Array("Andale".utf8), Array(tag.utf8))
        replace(Array("Andale".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] },
                Array(tag.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        return Data(bytes)
    }
}

@Suite("Word layout beside font registration", .serialized)
struct WordLayoutFontStressTests {
    /// Rounds per test; `PDFSUCHER_FONT_STRESS_REPEATS` raises it for a longer run.
    static let repeats = ProcessInfo.processInfo.environment["PDFSUCHER_FONT_STRESS_REPEATS"].flatMap(Int.init) ?? 6

    /// Word documents of 1 to ~10 pages and one of ~50.
    private static func documents(in dir: URL) throws -> [(url: URL, word: String)] {
        try (0..<6).map { i in
            let word = "Stresswort\(i)"
            let paragraphs = (0..<(i == 5 ? 1_200 : 1 + i * 60)).map { "\(word) Absatz \($0): Die Kündigungsfrist beträgt drei Monate zum Quartalsende." }
            return (try OfficeFixtures.docx(paragraphs: paragraphs, pageBreakAfter: i.isMultiple(of: 2) ? [0] : [],
                                            name: "Stress\(i).docx", in: dir), word)
        }
    }

    /// Whether someone holds `TextKitWordDocument.textKit` right now.
    private static func textKitBusy() -> Bool {
        guard TextKitWordDocument.textKit.try() else { return true }
        TextKitWordDocument.textKit.unlock()
        return false
    }

    /// One layout, every page queried and drawn.
    private static func exercise(_ url: URL, word: String, gate: FontRegistrationGate, mode: FontRegistrationGate.Mode) throws -> Bool {
        let document = try TextKitWordDocument(url: url, maxPages: 500, fontGate: gate, fonts: mode)
        var found = false
        for i in 0..<document.pageCount {
            let text = document.page(i).text
            if text.contains(word.lowercased()) || text.contains(word) { found = true }
            _ = document.thumbnail(i, maxPixel: 64)
        }
        return found && document.pageCount >= 1
    }

    @Test(.timeLimit(.minutes(3))) func parallelWordLayoutBesideRegistrationsNeitherCrashesNorDeadlocks() throws {
        #expect(FontResolver.officeFontRoots == .none)      // tests never read the real Office folders
        let dir = try PDFFixtures.tempDirectory()
        let documents = try Self.documents(in: dir)
        var folders: [URL] = []
        defer { folders.forEach(StressFonts.remove) }
        for round in 0..<Self.repeats {
            // The gate's registration: a real one (new families), started by the first `.start` layout; `.join`
            // layouts before it go on at once and run beside it.
            let gateFonts = try StressFonts.folder(count: 2)
            folders.append(gateFonts)
            let gate = FontRegistrationGate(timeout: .seconds(3)) { FontResolver.registerFonts(in: [gateFonts]) }
            let ok = Mutex(0), failures = Mutex<[String]>([])
            let workers = DispatchGroup(), registrations = DispatchGroup()
            let running = Mutex(true), direct = Mutex<[URL]>([])
            // Registrations of new families one after another, for as long as the layouts run.
            DispatchQueue.global(qos: .userInitiated).async(group: registrations) {
                while running.withLock({ $0 }) {
                    guard let single = try? StressFonts.folder(count: 1) else { break }
                    direct.withLock { $0.append(single) }
                    FontResolver.registerFonts(in: [single])
                }
            }
            defer { folders += direct.withLock { $0 } }
            for w in 0..<12 {
                let (url, word) = documents[w % documents.count]
                DispatchQueue.global(qos: w.isMultiple(of: 3) ? .utility : .userInitiated).async(group: workers) {
                    do {
                        if try Self.exercise(url, word: word, gate: gate, mode: w.isMultiple(of: 4) ? .start : .join) {
                            ok.withLock { $0 += 1 }
                        } else {
                            failures.withLock { $0.append("\(url.lastPathComponent): \(word) not found") }
                        }
                    } catch {
                        failures.withLock { $0.append("\(url.lastPathComponent): \(error)") }
                    }
                }
            }
            let finished = workers.wait(timeout: .now() + 60)
            running.withLock { $0 = false }
            let registered = registrations.wait(timeout: .now() + 30)
            #expect(finished == .success, "round \(round): Word layouts did not finish (deadlock?)")
            #expect(registered == .success, "round \(round): registrations did not finish (deadlock?)")
            guard finished == .success, registered == .success else { return }
            #expect(failures.withLock { $0 } == [], "round \(round)")
            #expect(ok.withLock { $0 } == 12, "round \(round)")
            #expect(gate.join(), "round \(round): the gate's registration is done")
        }
    }

    /// A layout cancelled while a registration waits for the font gate leaves the gate (between pages), so the
    /// registration finishes; no deadlock with the Indexer's cancelled or timed-out layout tasks. Since 1.3.2 the layout
    /// first waits for `TextKitWordDocument.textKit` (other suites may hold it): a round whose layout was still waiting
    /// when the registration started is cancelled before the import and does not exercise this; at least one round must
    /// (`textKit` held at that moment, by this layout as the suite is serialized).
    @Test(.timeLimit(.minutes(2))) func cancelledLayoutReleasesTheGateForAWaitingRegistration() async throws {
        #expect(FontResolver.officeFontRoots == .none)
        let dir = try PDFFixtures.tempDirectory()
        let paragraphs = (0..<4_000).map { "Absatz \($0): Die Kündigungsfrist beträgt drei Monate zum Quartalsende, schriftlich." }
        let long = try OfficeFixtures.docx(paragraphs: paragraphs, name: "Lang.docx", in: dir)
        let gate = FontRegistrationGate(timeout: .seconds(3)) {}
        _ = gate.wait()
        var exercised = 0
        for round in 0..<Self.repeats {
            let fonts = try StressFonts.folder(count: 1)
            defer { StressFonts.remove(fonts) }
            let layout = Task.detached(priority: .utility) {
                try TextKitWordDocument(url: long, maxPages: 10_000, fontGate: gate, fonts: .join).pageCount
            }
            try await Task.sleep(for: .milliseconds(20 + 15 * round))
            if Self.textKitBusy() { exercised += 1 }
            let registered = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                FontResolver.registerFonts(in: [fonts])
                registered.signal()
            }
            try await Task.sleep(for: .milliseconds(5))
            layout.cancel()
            let outcome = await layout.result
            switch outcome {
            case .success(let pages): #expect(pages > 1)          // finished before the cancel
            case .failure(let error): #expect(error is CancellationError, "round \(round): \(error)")
            }
            let done = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: registered.wait(timeout: .now() + 30)) }
            }
            #expect(done == .success, "round \(round): the registration still waits for the gate (deadlock?)")
        }
        #expect(exercised > 0, "no round had a layout inside TextKit when the registration started")
    }
}
