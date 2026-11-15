import AppKit
import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import OfficeKit

/// Task 4 (1.3 Office): Quick Look's Office generator writes an HTML preview via `qlmanage -p -o`.
@Suite("Quick Look HTML")
struct QuickLookHTMLTests {
    let dir: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
    }

    private static let slides = [
        "Folie 1: Übersicht – Größe",
        "Folie 2: Kündigungsfrist Müller",
        "Folie 3: Schlussbemerkung äöü",
    ]

    /// Records what `generate` launched, so the tests can check the process and its folder afterwards.
    private final class Launches: Sendable {
        let value = Mutex<[(pid: Int32, directory: URL)]>([])
        var all: [(pid: Int32, directory: URL)] { value.withLock { $0 } }
        func record(_ pid: Int32, _ directory: URL) { value.withLock { $0.append((pid, directory)) } }
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func slideCount(_ html: String) -> Int {
        html.components(separatedBy: #"<div class="slide""#).count - 1
    }

    @Test func generatesHTMLForPptx() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let output = try await QuickLookHTML().generate(for: deck)
        defer { output.remove() }
        #expect(FileManager.default.fileExists(atPath: output.html.path))
        #expect(output.html.path.hasPrefix(output.directory.path + "/"))
        #expect(output.directory.deletingLastPathComponent().lastPathComponent == "PDFSucher-QL")
        let html = try String(contentsOf: output.html, encoding: .utf8)
        #expect(html.contains("Kündigungsfrist"))
        #expect(slideCount(html) == 3)
    }

    @Test func fileNameWithSpacesAndUmlauts() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, name: "Präsentation äöü.pptx", in: dir)
        let output = try await QuickLookHTML().generate(for: deck)
        defer { output.remove() }
        let html = try String(contentsOf: output.html, encoding: .utf8)
        #expect(html.contains("Kündigungsfrist"))
    }

    @Test func hiddenSlidesAndSlideNumberFieldsInFixture() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, hidden: [1], slideNumberFieldOn: [2], in: dir)
        let output = try await QuickLookHTML().generate(for: deck)
        defer { output.remove() }
        let html = try String(contentsOf: output.html, encoding: .utf8)
        #expect(slideCount(html) == 2) // Quick Look leaves hidden slides out
        #expect(!html.contains("Kündigungsfrist"))
        #expect(html.contains("Schlussbemerkung"))
        #expect(html.contains("‹#›"))
    }

    @Test func noPreviewForGarbage() async throws {
        let garbage = dir.appendingPathComponent("x.pptx")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        let launches = Launches()
        let generator = QuickLookHTML(onLaunch: launches.record)
        await #expect(throws: QuickLookError.noPreview(garbage)) {
            try await generator.generate(for: garbage)
        }
        let launched = try #require(launches.all.first)
        #expect(!FileManager.default.fileExists(atPath: launched.directory.path))
    }

    @Test func removeDeletesDirectory() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let output = try await QuickLookHTML().generate(for: deck)
        #expect(FileManager.default.fileExists(atPath: output.directory.path))
        output.remove()
        #expect(!FileManager.default.fileExists(atPath: output.directory.path))
    }

    // MARK: Stopping a process that would not end on its own (independent of how fast qlmanage is)
    // Upper time bounds are generous (load from parallel tests) but far below the 30 s the process would run.

    private static let sleep30 = QuickLookHTML.Command(executable: URL(fileURLWithPath: "/bin/sleep")) { _, _ in ["30"] }
    /// Ignores SIGTERM (inherited across `exec`, so no orphaned child remains); only SIGKILL ends it.
    private static let sleepIgnoringTerm = QuickLookHTML.Command(executable: URL(fileURLWithPath: "/bin/sh")) { _, _ in
        ["-c", "trap '' TERM; exec /bin/sleep 30"]
    }

    @Test func timeoutKillsProcess() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let launches = Launches()
        let generator = QuickLookHTML(timeout: .milliseconds(50), command: Self.sleep30, onLaunch: launches.record)
        let clock = ContinuousClock(), start = clock.now
        await #expect(throws: QuickLookError.timedOut(deck)) {
            try await generator.generate(for: deck)
        }
        #expect(clock.now - start < .seconds(10))
        let launched = try #require(launches.all.first)
        #expect(!Self.isRunning(launched.pid))
        #expect(!FileManager.default.fileExists(atPath: launched.directory.path))
    }

    @Test func timeoutKillsProcessIgnoringTerm() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let launches = Launches()
        let generator = QuickLookHTML(timeout: .milliseconds(500), command: Self.sleepIgnoringTerm,
                                      killGrace: .milliseconds(300), onLaunch: launches.record)
        let clock = ContinuousClock(), start = clock.now
        await #expect(throws: QuickLookError.timedOut(deck)) {
            try await generator.generate(for: deck)
        }
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(800)) // SIGTERM was ignored, SIGKILL after the grace ended it
        #expect(elapsed < .seconds(10))
        let launched = try #require(launches.all.first)
        #expect(!Self.isRunning(launched.pid))
        #expect(!FileManager.default.fileExists(atPath: launched.directory.path))
    }

    @Test func cancellationKillsProcess() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let launches = Launches()
        let (launched, continuation) = AsyncStream<Void>.makeStream()
        let generator = QuickLookHTML(command: Self.sleep30, onLaunch: { pid, directory in
            launches.record(pid, directory)
            continuation.yield()
        })
        let clock = ContinuousClock(), start = clock.now
        let task = Task { try await generator.generate(for: deck) }
        Task { _ = await task.result; continuation.finish() }
        for await _ in launched { break }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.now - start < .seconds(10))
        let launch = try #require(launches.all.first)
        #expect(!Self.isRunning(launch.pid))
        #expect(!FileManager.default.fileExists(atPath: launch.directory.path))
    }

    /// Leftovers of a crashed run (folders older than the limit) are removed; younger ones — a run that is still
    /// writing, possibly in another process — stay.
    @Test func sweepRemovesOnlyOldLeftovers() throws {
        let base = dir.appendingPathComponent("PDFSucher-QL", isDirectory: true)
        let old = base.appendingPathComponent("alt", isDirectory: true)
        let young = base.appendingPathComponent("jung", isDirectory: true)
        let oldFile = base.appendingPathComponent("lose.html")
        for folder in [old, young] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("x.qlpreview"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("x.qlpreview/Preview.html"))
        }
        try Data("x".utf8).write(to: oldFile)
        let past = Date().addingTimeInterval(-20 * 60)
        for item in [old, oldFile] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: item.path) }

        #expect(QuickLookHTML.sweepLeftovers(in: base) == 2)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: young.appendingPathComponent("x.qlpreview/Preview.html").path))
        // A missing folder is fine.
        #expect(QuickLookHTML.sweepLeftovers(in: dir.appendingPathComponent("gibtsnicht")) == 0)
        #expect(QuickLookHTML.leftoverRoot == FileManager.default.temporaryDirectory.appendingPathComponent("PDFSucher-QL", isDirectory: true))
    }

    @Test func missingGenerator() async throws {
        let deck = try OfficeFixtures.pptx(slides: Self.slides, in: dir)
        let generator = QuickLookHTML(generatorPath: dir.appendingPathComponent("Fehlt.qlgenerator").path)
        await #expect(throws: QuickLookError.generatorMissing) {
            try await generator.generate(for: deck)
        }
    }

    @Test func fixtureDocxReadsAsAttributedString() throws {
        let png = dir.appendingPathComponent("bild.png")
        try ImageFixtures.makeImage(at: png, text: "Bild", size: CGSize(width: 120, height: 60), format: .png)
        let document = try OfficeFixtures.docx(paragraphs: ["Erster Absatz – Größe", "Zweiter Absatz Übung", "Dritter"],
                                               pageBreakAfter: [0], imagePNG: Data(contentsOf: png), in: dir)
        let text = try TextKitWordDocument.textKit.withLock {   // Word import: under the Word TextKit lock, as in the app
            try NSAttributedString(url: document, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                   documentAttributes: nil).string
        }
        #expect(text.contains("Erster Absatz – Größe"))
        #expect(text.contains("Zweiter Absatz Übung"))
        #expect(text.contains("\u{0C}")) // page break → form feed
    }
}
