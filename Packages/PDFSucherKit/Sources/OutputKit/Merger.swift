// Merger.swift — Task 3.2
import Foundation
import OSLog
import PDFKit

public enum OutputError: Error, Equatable {
    /// `reason`: why writing failed, readable for the user (the underlying error's
    /// `localizedDescription`, or „PDFKit konnte die Datei nicht schreiben“).
    case cannotOpen(URL), pageOutOfRange(PageRef), writeFailed(URL, reason: String), emptySelection

    static let pdfKitWriteFailed = "PDFKit konnte die Datei nicht schreiben"
    static let incomplete = "Die gespeicherte Datei ist unvollständig"
}

/// PDFKit produced no data for the merged document.
private struct PDFKitWriteError: Error {}
/// The temporary file does not hold what was written (seen with `PDFDocument.write(to:)` on a full volume).
private struct IncompleteWriteError: Error {}

let outputLog = Logger(subsystem: "local.pdfsucher", category: "output")

/// Copies selected pages from one or more PDFs into a new document. Source files are only read.
/// Value type without state: build it wherever the work runs (e.g. inside a background task).
public struct Merger: Sendable {
    /// Writes the PDF bytes to a file; replaceable in tests to simulate failures (e.g. a full volume).
    private let writeData: @Sendable (Data, URL) throws -> Void
    /// Pages of files it `handles` (Word, PowerPoint); nil = only PDFs and images, as before 1.3.
    private let foreign: (any ForeignPageProvider)?

    public init(foreign: (any ForeignPageProvider)? = nil) {
        self.init(writeData: { data, url in try data.write(to: url) }, foreign: foreign)
    }

    init(writeData: @escaping @Sendable (Data, URL) throws -> Void, foreign: (any ForeignPageProvider)? = nil) {
        self.writeData = writeData
        self.foreign = foreign
    }

    /// Pages that cannot be merged or printed now: file missing, not a readable unlocked PDF (or, for
    /// image files, not decodable by ImageIO), or the page index beyond the file's current page count
    /// (images have exactly page 0) — the same checks as `makeDocument`. Files `foreign` handles have the pages its
    /// `pageCount(of:)` reports (nil → all unavailable).
    public static func unavailable(_ refs: [PageRef], foreign: (any ForeignPageProvider)? = nil) -> Set<PageRef> {
        var pageCounts: [URL: Int?] = [:]
        var result: Set<PageRef> = []
        for ref in refs {
            if pageCounts[ref.url] == nil {
                if let foreign, foreign.handles(ref.url) {
                    pageCounts[ref.url] = .some(foreign.pageCount(of: ref.url))
                } else if ImagePages.isImage(ref.url) {
                    // An image is a document with exactly one page (spec 1.2 §4).
                    pageCounts[ref.url] = .some(ImagePages.isReadable(ref.url) ? 1 : nil)
                } else {
                    let document = PDFDocument(url: ref.url)
                    pageCounts[ref.url] = .some(document.flatMap { $0.isLocked ? nil : $0.pageCount })
                }
            }
            guard let count = pageCounts[ref.url] ?? nil, ref.pageIndex >= 0, ref.pageIndex < count else {
                result.insert(ref)
                continue
            }
        }
        return result
    }

    /// A new in-memory document with the pages of `refs`, in exactly that order. Refs to image files
    /// (`ImagePages.isImage`, pageIndex 0) become A4 image pages (`ImagePages.makePage`); refs to files the
    /// `foreign` provider handles come from it (`cannotOpen` when it reports no page count, `pageOutOfRange` beyond it).
    /// Each source file is opened once. Throws before producing anything if any page is unavailable.
    /// Internal links point to the merged copy of their target page (its first occurrence)
    /// and are removed when that page is not part of the merge.
    public func makeDocument(_ refs: [PageRef]) throws -> PDFDocument {
        guard !refs.isEmpty else { throw OutputError.emptySelection }
        var sources: [URL: PDFDocument] = [:]
        var outputIndex: [PageRef: Int] = [:]
        var links: [(annotation: PDFAnnotation, target: PageRef?, point: CGPoint)] = []
        let result = PDFDocument()
        var foreignCounts: [URL: Int?] = [:]
        for ref in refs {
            if let foreign, foreign.handles(ref.url) {
                // Foreign pages carry no internal links.
                let count = foreignCounts[ref.url] ?? foreign.pageCount(of: ref.url)
                foreignCounts[ref.url] = .some(count)
                let page = try Self.foreignPage(ref, count: count, from: foreign)
                if outputIndex[ref] == nil { outputIndex[ref] = result.pageCount }
                result.insert(page, at: result.pageCount)
                continue
            }
            if ImagePages.isImage(ref.url) {
                // Image files become their own A4 page (spec 1.2 §6); they carry no links.
                guard ref.pageIndex == 0 else {
                    outputLog.error("Page \(ref.pageIndex) out of range (image) in \(ref.url.path, privacy: .public)")
                    throw OutputError.pageOutOfRange(ref)
                }
                let page = try ImagePages.makePage(from: ref.url)
                if outputIndex[ref] == nil { outputIndex[ref] = result.pageCount }
                result.insert(page, at: result.pageCount)
                continue
            }
            let source: PDFDocument
            if let open = sources[ref.url] {
                source = open
            } else {
                // A locked (password-protected) document exposes no page content.
                guard let opened = PDFDocument(url: ref.url), !opened.isLocked else {
                    outputLog.error("Cannot open \(ref.url.path, privacy: .public)")
                    throw OutputError.cannotOpen(ref.url)
                }
                sources[ref.url] = opened
                source = opened
            }
            guard ref.pageIndex >= 0, ref.pageIndex < source.pageCount else {
                outputLog.error("Page \(ref.pageIndex) out of range (\(source.pageCount) pages) in \(ref.url.path, privacy: .public)")
                throw OutputError.pageOutOfRange(ref)
            }
            guard let page = source.page(at: ref.pageIndex), let copy = page.copy() as? PDFPage else {
                outputLog.error("Cannot copy page \(ref.pageIndex) of \(ref.url.path, privacy: .public)")
                throw OutputError.cannotOpen(ref.url)
            }
            // copy() keeps annotation order, so originals and copies pair up by position;
            // the type/bounds check makes a silent mismatch impossible.
            for (original, copied) in zip(page.annotations, copy.annotations) {
                guard original.type == copied.type, original.bounds == copied.bounds,
                      let destination = Self.internalDestination(of: original) else { continue }
                let target = destination.page.map { PageRef(url: ref.url, pageIndex: source.index(for: $0)) }
                links.append((copied, target, destination.point))
            }
            if outputIndex[ref] == nil { outputIndex[ref] = result.pageCount }
            result.insert(copy, at: result.pageCount)
        }
        for link in links {
            if let target = link.target, let index = outputIndex[target], let page = result.page(at: index) {
                let destination = PDFDestination(page: page, at: link.point)
                if link.annotation.action is PDFActionGoTo {
                    link.annotation.action = PDFActionGoTo(destination: destination)
                } else {
                    link.annotation.destination = destination
                }
            } else {
                link.annotation.page?.removeAnnotation(link.annotation)
            }
        }
        return result
    }

    private static func foreignPage(_ ref: PageRef, count: Int?, from foreign: any ForeignPageProvider) throws -> PDFPage {
        guard let count else {
            outputLog.error("Cannot open \(ref.url.path, privacy: .public) (no pages)")
            throw OutputError.cannotOpen(ref.url)
        }
        guard ref.pageIndex >= 0, ref.pageIndex < count else {
            outputLog.error("Page \(ref.pageIndex) out of range (\(count) pages) in \(ref.url.path, privacy: .public)")
            throw OutputError.pageOutOfRange(ref)
        }
        do {
            return try foreign.makePage(ref)
        } catch let error as OutputError {
            throw error
        } catch {
            outputLog.error("Cannot make page \(ref.pageIndex) of \(ref.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw OutputError.cannotOpen(ref.url)
        }
    }

    private static func internalDestination(of annotation: PDFAnnotation) -> PDFDestination? {
        guard annotation.type == "Link" else { return nil }
        return (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
    }

    /// Writes the merged document to `url`. An existing file is replaced atomically and keeps its
    /// permissions and extended attributes (e.g. Finder tags); on any failure it is left unchanged.
    public func write(_ refs: [PageRef], to url: URL) throws {
        let document = try makeDocument(refs)
        let fm = FileManager.default
        do {
            let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fm.removeItem(at: tempDir) }
            let temp = tempDir.appendingPathComponent(url.lastPathComponent)
            // Not `document.write(to:)`: on a full volume it reported success and left half a file.
            guard let data = document.dataRepresentation() else { throw PDFKitWriteError() }
            try writeData(data, temp)
            let written = (try fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue
            guard written == data.count, let check = PDFDocument(url: temp), check.pageCount == document.pageCount else {
                throw IncompleteWriteError()
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            outputLog.error("Writing \(url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw OutputError.writeFailed(url, reason: Self.reason(for: error, destination: url))
        }
    }

    /// Short German reason for the common causes (spec §6: „Kein Schreibrecht“, „Volume voll“);
    /// otherwise the system's own text.
    static func reason(for error: Error, destination: URL) -> String {
        switch error {
        case is PDFKitWriteError: return OutputError.pdfKitWriteFailed
        case is IncompleteWriteError: return OutputError.incomplete
        default: break
        }
        let folder = destination.deletingLastPathComponent().lastPathComponent
        let noPermission = "Kein Schreibrecht für den Ordner „\(folder)“"
        let full = "Volume voll"
        let readOnly = "Volume ist schreibgeschützt"
        // ENOENT may also mean a vanished temporary file: name the folder only if it is really gone.
        let folderGone = !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path)
        let missing = folderGone ? "Ordner „\(folder)“ existiert nicht (mehr)" : error.localizedDescription
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteNoPermission: return noPermission
            case .fileWriteOutOfSpace: return full
            case .fileWriteVolumeReadOnly: return readOnly
            case .fileNoSuchFile, .fileReadNoSuchFile: return missing
            default: break
            }
        }
        if let code = posixCode(of: error) {
            switch code {
            case .EACCES, .EPERM: return noPermission
            case .ENOSPC, .EDQUOT: return full
            case .EROFS: return readOnly
            case .ENOENT: return missing
            default: break
            }
        }
        return error.localizedDescription
    }

    /// The POSIX code of the error itself or of its underlying error.
    private static func posixCode(of error: Error) -> POSIXErrorCode? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return POSIXErrorCode(rawValue: Int32(ns.code)) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return posixCode(of: underlying) }
        return nil
    }
}
