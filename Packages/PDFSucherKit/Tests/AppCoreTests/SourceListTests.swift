import Foundation
import SearchKit
import Testing
import TestSupport
@testable import AppCore

/// Spec 1.1 §4 „Überschneidungen“: no file twice, children inside a loaded folder are not added,
/// a parent folder replaces its loaded children.
@Suite("Source list rules")
struct SourceListTests {
    private func folder(_ p: String) -> LoadedSourceRef { LoadedSourceRef(url: URL(fileURLWithPath: p, isDirectory: true), isFolder: true) }
    private func file(_ p: String) -> LoadedSourceRef { LoadedSourceRef(url: URL(fileURLWithPath: p), isFolder: false) }

    @Test func addChildOfLoadedFolderIsAlreadyContained() {
        var list = SourceList()
        _ = list.add([folder("/a")])
        let result = list.add([folder("/a/sub"), file("/a/sub/x.pdf")])
        #expect(result.added.isEmpty)
        #expect(result.alreadyContained == [Containment(url: folder("/a/sub").url, container: folder("/a").url),
                                            Containment(url: file("/a/sub/x.pdf").url, container: folder("/a").url)])
        #expect(list.items == [folder("/a")])
    }

    @Test func addParentReplacesChildren() {
        var list = SourceList()
        _ = list.add([folder("/a/sub"), file("/a/x.pdf"), file("/b/y.pdf")])
        let result = list.add([folder("/a")])
        #expect(result.added == [folder("/a")])
        #expect(result.replaced == [folder("/a/sub"), file("/a/x.pdf")])
        #expect(list.items == [file("/b/y.pdf"), folder("/a")])
    }

    @Test func standardizedPathsDeduplicate() {
        var list = SourceList()
        let result = list.add([folder("/a/"), folder("/a/../a"), file("/b/./y.pdf"), file("/b/y.pdf")])
        #expect(list.items.map(\.url.path) == ["/a", "/b/y.pdf"])
        #expect(result.added.count == 2)
        let again = list.add([folder("/a")])
        #expect(again.added.isEmpty)
        #expect(list.items.count == 2)
    }

    @Test func siblingPrefixIsNotContainment() {
        var list = SourceList()
        _ = list.add([folder("/a")])
        let result = list.add([folder("/ab"), file("/a.pdf")])
        #expect(result.added == [folder("/ab"), file("/a.pdf")])
        #expect(result.alreadyContained.isEmpty)
    }

    @Test func removeKnownAndUnknown() {
        var list = SourceList()
        _ = list.add([folder("/a"), file("/b.pdf")])
        let removedKnown = list.remove(URL(fileURLWithPath: "/a/"))
        let removedUnknown = list.remove(URL(fileURLWithPath: "/zzz"))
        #expect(removedKnown)
        #expect(!removedUnknown)
        #expect(list.items == [file("/b.pdf")])
        list.removeAll()
        #expect(list.items.isEmpty)
    }

    /// Review of Task 1: a parent and its children in one batch (Finder list view with an expanded folder).
    @Test func parentAndChildrenInOneBatch() {
        var list = SourceList()
        _ = list.add([file("/b/y.pdf")])
        let result = list.add([folder("/a/sub"), file("/a/x.pdf"), folder("/a")])
        #expect(result.added == [folder("/a")])
        #expect(result.replaced.isEmpty)
        #expect(list.items == [file("/b/y.pdf"), folder("/a")])
    }

    /// Review of Task 1: restored or directly added URLs bypass the classifier; a symlinked folder
    /// inside a loaded folder must still count as contained.
    @Test func symlinkedChildIsContained() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = dir.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: docs.appendingPathComponent("sub"))
        var list = SourceList()
        _ = list.add([LoadedSourceRef(url: docs, isFolder: true)])
        let result = list.add([LoadedSourceRef(url: link, isFolder: true)])
        #expect(result.added.isEmpty)
        #expect(result.alreadyContained.count == 1)
    }

    @Test func initDeduplicates() {
        #expect(SourceList([folder("/a"), folder("/a/"), file("/a/x.pdf")]).items == [folder("/a")])
    }

    /// Review of Task 1: equality must not depend on how the URL was spelled, also after decoding.
    @Test func refEqualityIgnoresURLSpelling() throws {
        let plain = LoadedSourceRef(url: URL(fileURLWithPath: "/a/../a"), isFolder: true)
        #expect(plain == folder("/a/"))
        let json = Data(#"{"url":"file:\/\/\/a\/.\/b.pdf","isFolder":false}"#.utf8)
        #expect(try JSONDecoder().decode(LoadedSourceRef.self, from: json) == file("/a/b.pdf"))
    }

    @Test func classifyResolvesSymlinksAndCase() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let sub = dir.appendingPathComponent("Ordner", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let upper = dir.appendingPathComponent("GROSS.PDF")
        try PDFFixtures.makePDF(at: upper, pages: ["x"])
        let target = sub.appendingPathComponent("ziel.pdf")
        try PDFFixtures.makePDF(at: target, pages: ["x"])
        let link = dir.appendingPathComponent("verweis.pdf")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let text = dir.appendingPathComponent("notiz.txt")
        try Data("x".utf8).write(to: text)
        let app = dir.appendingPathComponent("Programm.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)

        let (sources, ignored) = SourceClassifier.classify([sub, upper, link, text, app])
        let resolvedDir = dir.resolvingSymlinksInPath()
        #expect(sources == [LoadedSourceRef(url: resolvedDir.appendingPathComponent("Ordner", isDirectory: true), isFolder: true),
                            LoadedSourceRef(url: resolvedDir.appendingPathComponent("GROSS.PDF"), isFolder: false),
                            LoadedSourceRef(url: resolvedDir.appendingPathComponent("Ordner/ziel.pdf"), isFolder: false)])
        #expect(ignored == [text, app])
    }

    /// Final review: a Finder alias to a folder (or PDF) is followed, not ignored.
    @Test func classifyFollowsFinderAliases() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Ziel", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("Ziel Alias")
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let (sources, ignored) = SourceClassifier.classify([alias])
        #expect(ignored.isEmpty)
        #expect(sources == [LoadedSourceRef(url: target.resolvingSymlinksInPath(), isFolder: true)])
    }
}
