import Foundation
import SearchKit
import Testing
@testable import ViewerUI

/// Spec 1.1 §4: „Quellen (n)“, drop prompt, source folder in the row header with several sources.
@Suite("Sources UI texts")
struct SourcesViewTests {
    private func hit(root: String, path: String, file: Bool = false) -> DocumentHit {
        let rootURL = URL(fileURLWithPath: root, isDirectory: !file)
        let url = file ? rootURL : rootURL.appendingPathComponent(path)
        return DocumentHit(url: url, relativePath: path, modifiedAt: .distantPast, pageHits: [], totalMatches: 0,
                           relevance: 0, sourceRoot: rootURL, pageCount: 0)
    }

    @Test func sourcesTitleCounts() {
        #expect(ViewerText.sourcesTitle(count: 0) == "Quellen (0)")
        #expect(ViewerText.sourcesTitle(count: 3) == "Quellen (3)")
        #expect(ViewerText.dropPrompt == "Zum Hinzufügen loslassen")
    }

    @Test func rowShowsSourceOnlyWithSeveralSources() {
        let nested = hit(root: "/Users/x/Verträge", path: "2024/a.pdf")
        #expect(ViewerText.rowFolder(nested, showSource: false) == "2024")
        #expect(ViewerText.rowFolder(nested, showSource: true) == "Verträge/2024")
        let top = hit(root: "/Users/x/Verträge", path: "a.pdf")
        #expect(ViewerText.rowFolder(top, showSource: false) == "")
        #expect(ViewerText.rowFolder(top, showSource: true) == "Verträge")
        let single = hit(root: "/Users/x/Downloads/rechnung.pdf", path: "rechnung.pdf", file: true)
        #expect(ViewerText.rowFolder(single, showSource: true) == "Downloads")
        #expect(ViewerText.rowFolder(single, showSource: false) == "")
    }

    @Test func sourcesMenuListsEveryRemovable() {
        let sources = [LoadedSourceRef(url: URL(fileURLWithPath: "/a/Verträge"), isFolder: true),
                       LoadedSourceRef(url: URL(fileURLWithPath: "/b/rechnung.pdf"), isFolder: false)]
        let entries = SourcesMenu.entries(sources)
        #expect(entries.map(\.title) == ["Verträge", "rechnung.pdf"])
        #expect(entries.map(\.detail) == ["/a/Verträge", "/b/rechnung.pdf"])
        #expect(entries.map(\.symbol) == ["folder", "doc.richtext"])
        #expect(SourcesMenu.removeAllTitle == "Alle entfernen")
    }

    /// Review of Task 3: Finder may hand over file reference URLs (file:///.file/id=…).
    @Test func dropResolvesFileReferenceURLs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Drop-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: file)
        let reference = try #require((file as NSURL).fileReferenceURL())
        #expect(reference.path != file.path || reference.absoluteString.contains(".file/id="))
        #expect(DropLoader.fileURL(reference).resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
        #expect(DropLoader.fileURL(file) == file)
    }

    @Test func menuEntriesHaveSpokenRemoveLabels() {
        let entries = SourcesMenu.entries([LoadedSourceRef(url: URL(fileURLWithPath: "/a/Verträge"), isFolder: true)])
        #expect(entries.map(\.accessibilityLabel) == ["„Verträge“ entfernen"])
    }
}
