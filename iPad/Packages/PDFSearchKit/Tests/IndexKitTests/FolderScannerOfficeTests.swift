import Testing
import Foundation
import IndexKit
import TestSupport

@Suite("FolderScanner Office")
struct FolderScannerOfficeTests {
    private let fm = FileManager.default

    private func touch(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func officeFilesListedOnlyWhenEnabled() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        for name in ["a.pdf", "b.DOCX", "c.pptx", "d.ppt", "e.potx"] {
            try touch(root.appendingPathComponent(name))
        }
        #expect(try FolderScanner().scan(root: root).map(\.relativePath) == ["a.pdf"])
        #expect(try FolderScanner(includeOffice: true).scan(root: root).map(\.relativePath)
                == ["a.pdf", "b.DOCX", "c.pptx"])
    }

    @Test func lockFilesIgnored() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: root) }
        for name in ["b.docx", "~$b.docx", "~$c.pptx", "~$d.pdf"] {
            try touch(root.appendingPathComponent(name))
        }
        #expect(try FolderScanner(includeOffice: true).scan(root: root).map(\.relativePath) == ["b.docx"])
    }

    @Test func kindFromExtension() {
        #expect(DocumentKind(fileExtension: "PPTM") == .powerpoint)
        #expect(DocumentKind(fileExtension: "doc") == .word)
        #expect(DocumentKind(fileExtension: "dotx") == .word)
        #expect(DocumentKind(fileExtension: "ppt") == nil)
        #expect(DocumentKind(fileExtension: "potx") == nil)
        #expect(DocumentKind.word.isOffice && DocumentKind.powerpoint.isOffice)
        #expect(!DocumentKind.pdf.isOffice && !DocumentKind.image.isOffice)
    }
}
