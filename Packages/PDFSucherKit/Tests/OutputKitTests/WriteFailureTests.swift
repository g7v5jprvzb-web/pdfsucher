import Foundation
import PDFKit
import Testing
import TestSupport
@testable import OutputKit

/// Review of Task 5.2: a full volume must be reported („Volume voll“) and must never replace an
/// existing file with a truncated one; reasons are short German texts for the common causes.
@Suite("Merger write failures")
struct WriteFailureTests {
    let dir: URL
    let source: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
        source = dir.appendingPathComponent("A.pdf")
        try PDFFixtures.makePDF(at: source, pages: ["Alpha null", "Alpha eins"])
    }

    private func failure(_ error: Error, existing: Bool = true) throws -> (reason: String, out: URL) {
        let out = dir.appendingPathComponent("Auswahl.pdf")
        if existing { try Data("alt".utf8).write(to: out) }
        let merger = Merger(writeData: { _, _ in throw error })
        let thrown = #expect(throws: OutputError.self) {
            try merger.write([PageRef(url: source, pageIndex: 0)], to: out)
        }
        guard case .writeFailed(let url, let reason) = thrown else {
            Issue.record("expected writeFailed, got \(String(describing: thrown))")
            return ("", out)
        }
        #expect(url == out)
        return (reason, out)
    }

    @Test func outOfSpaceIsReportedAndKeepsExistingFile() throws {
        let (reason, out) = try failure(CocoaError(.fileWriteOutOfSpace))
        #expect(reason == "Volume voll")
        #expect(try Data(contentsOf: out) == Data("alt".utf8))
    }

    @Test func posixOutOfSpaceIsReported() throws {
        #expect(try failure(POSIXError(.ENOSPC)).reason == "Volume voll")
        let wrapped = CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EDQUOT)])
        #expect(try failure(wrapped).reason == "Volume voll")
    }

    @Test func noPermissionNamesTheFolder() throws {
        let name = dir.lastPathComponent
        #expect(try failure(CocoaError(.fileWriteNoPermission)).reason == "Kein Schreibrecht für den Ordner „\(name)“")
        #expect(try failure(POSIXError(.EACCES)).reason == "Kein Schreibrecht für den Ordner „\(name)“")
    }

    @Test func readOnlyVolume() throws {
        #expect(try failure(CocoaError(.fileWriteVolumeReadOnly)).reason == "Volume ist schreibgeschützt")
        #expect(try failure(POSIXError(.EROFS)).reason == "Volume ist schreibgeschützt")
    }

    @Test func missingFolder() throws {
        let missing = dir.appendingPathComponent("weg/Auswahl.pdf")
        let thrown = #expect(throws: OutputError.self) {
            try Merger().write([PageRef(url: source, pageIndex: 0)], to: missing)
        }
        guard case .writeFailed(_, let reason) = thrown else { Issue.record("expected writeFailed"); return }
        #expect(reason == "Ordner „weg“ existiert nicht (mehr)")
    }

    @Test func missingFileInExistingFolderIsNotCalledMissingFolder() throws {
        // ENOENT can also mean a vanished temp file; the folder exists, so use the system text.
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                            userInfo: [NSLocalizedDescriptionKey: "Datei fehlt"])
        #expect(try failure(error).reason == "Datei fehlt")
        #expect(try failure(CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Weg"])).reason == "Weg")
    }

    @Test func otherErrorsFallBackToSystemText() throws {
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Etwas Seltenes"])
        #expect(try failure(error).reason == "Etwas Seltenes")
    }

    @Test func truncatedWriteIsDetected() throws {
        // What PDFKit did on a full volume: success reported, half a file on disk.
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Data("alt".utf8).write(to: out)
        let merger = Merger(writeData: { data, url in try data.prefix(data.count / 2).write(to: url) })
        let thrown = #expect(throws: OutputError.self) {
            try merger.write([PageRef(url: source, pageIndex: 0), PageRef(url: source, pageIndex: 1)], to: out)
        }
        guard case .writeFailed(_, let reason) = thrown else { Issue.record("expected writeFailed"); return }
        #expect(reason == "Die gespeicherte Datei ist unvollständig")
        #expect(try Data(contentsOf: out) == Data("alt".utf8))
    }

    /// Opt-in (`PDFSUCHER_DISKFULL=1`): a real, nearly full 2 MB disk image.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_DISKFULL"] == "1"))
    func realFullVolume() throws {
        let image = dir.appendingPathComponent("voll.dmg")
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "hdiutil \(args.joined(separator: " "))")
        }
        try run(["create", "-size", "2m", "-fs", "HFS+", "-volname", "Voll", image.path])
        try run(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? run(["detach", "-force", mount.path]) }
        // Big source (many pages of text), then fill the volume.
        let big = dir.appendingPathComponent("gross.pdf")
        try PDFFixtures.makePDF(at: big, pages: (0..<200).map { "Seite \($0) " + String(repeating: "Vertrag Laufzeit Kündigung ", count: 40) })
        let out = mount.appendingPathComponent("Auswahl.pdf")
        try Data("alt".utf8).write(to: out)
        let free = (try mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0
        try Data(count: max(free - 100_000, 0)).write(to: mount.appendingPathComponent("fuell.bin"))
        let thrown = #expect(throws: OutputError.self) {
            try Merger().write((0..<200).map { PageRef(url: big, pageIndex: $0) }, to: out)
        }
        guard case .writeFailed(_, let reason) = thrown else { Issue.record("expected writeFailed"); return }
        #expect(reason == "Volume voll" || reason == "Die gespeicherte Datei ist unvollständig")
        #expect(try Data(contentsOf: out) == Data("alt".utf8))
    }
}
