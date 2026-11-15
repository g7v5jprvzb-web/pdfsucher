// SingleFileLayout.swift — 1.3 Teil B Task 5 (Word/PowerPoint as single-file sources, laid out in memory)
import Foundation
import IndexKit
import SearchKit

/// Where a Word/PowerPoint single file stands: waiting for (or in) its layout, laid out from the file
/// version `FileStamp`, or unreadable (damaged, encrypted, unsupported, or too slow) in version `FileStamp`.
/// A laid-out or unreadable file whose version changed counts as waiting again (it is laid out anew).
enum FileLayoutState: Sendable, Equatable {
    case pending
    case laidOut(LayoutResult, FileStamp?)
    case failed(String, FileStamp?)

    var isPending: Bool { self == .pending }

    /// The file version a finished state belongs to (nil while waiting).
    var stamp: FileStamp?? {
        switch self {
        case .pending: nil
        case .laidOut(_, let stamp), .failed(_, let stamp): .some(stamp)
        }
    }
}

/// The page texts of a laid-out single file: the result's pages while the file is the version they were
/// made from. A waiting file has no text yet; an unreadable one throws `TextSourceError.unreadable`, so the
/// search shows its hint. A file that changed since throws `StaleFileLayout` (checked here, at read time,
/// so a change just before the search never shows „kein Text“ and nothing is cached for the new version).
struct LaidOutTextSource: TextSource {
    let state: FileLayoutState

    init(state: FileLayoutState) { self.state = state }

    func pages(of url: URL) throws -> [PageText] {
        switch state {
        case .pending:
            return []
        case .failed(_, let stamp):
            guard FileStamp.of(url) == stamp else { throw StaleFileLayout() }
            throw TextSourceError.unreadable(url)
        case .laidOut(let result, let stamp):
            guard FileStamp.of(url) == stamp else { throw StaleFileLayout() }
            return result.pages.enumerated().map { PageText(pageIndex: $0.offset, text: $0.element.text) }
        }
    }
}

/// The search of a single file found its layout (or its „unreadable“) older than the file: it is laid out
/// again (no hint).
struct StaleFileLayout: Error {}

enum SingleFileLayout {
    /// The kind of a Word/PowerPoint file, nil for PDFs, images and anything else.
    static func officeKind(_ url: URL) -> DocumentKind? {
        switch SupportedSourceTypes.kind(forExtension: url.pathExtension) {
        case .word?: .word
        case .powerpoint?: .powerpoint
        default: nil
        }
    }

    /// A laid-out or unreadable state whose file changed since.
    static func isStale(_ url: URL, _ state: FileLayoutState?) -> Bool {
        guard let stamp = state?.stamp else { return false }
        return FileStamp.of(url) != stamp
    }

    /// The simplified renderer (spec 1.3: „vereinfacht“).
    static func isSimplified(_ state: FileLayoutState?) -> Bool {
        guard case .laidOut(let result, _)? = state else { return false }
        return StoredDocument.isSimplifiedRenderer(result.renderer)
    }

    /// The search of one Office single file in `state` (a new page cache for every state).
    static func search(_ url: URL, kind: DocumentKind, state: FileLayoutState) -> SingleDocumentSearch {
        SingleDocumentSearch(source: LaidOutTextSource(state: state), kind: kind, isSimplified: isSimplified(state))
    }

    /// One layout run raced against `timeout` and cancellation (like `Indexer.layOut`, through `LayoutRace`):
    /// neither waits for a source that ignores cancellation; its late answer is dropped.
    /// - `.laidOut` / `.failed` (unreadable, time limit) with the file version from before the layout,
    /// - `.pending` when the file changed meanwhile (lay out again; a file still being copied is not
    ///   marked unreadable),
    /// - `.failure(CancellationError)` when cancelled, `.failure(other)` for any other error (try later).
    static func run(_ url: URL, kind: DocumentKind, source: any PageLayoutSource,
                    timeout: Duration) async -> Result<FileLayoutState, Error> {
        let before = FileStamp.of(url)
        let race = LayoutRace<Result<FileLayoutState, Error>>()
        let work = Task.detached(priority: .utility) {
            race.finish(await attempt(url, kind: kind, source: source, before: before))
        }
        let timer = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: timeout) } catch { return }
            race.finish(.success(FileStamp.of(url) == before ? .failed("Zeitlimit", before) : .pending))
        }
        race.track(work: work, timer: timer)
        return await withTaskCancellationHandler {
            await race.outcome()
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private static func attempt(_ url: URL, kind: DocumentKind, source: any PageLayoutSource,
                                before: FileStamp?) async -> Result<FileLayoutState, Error> {
        do {
            let result = try await source.layout(of: url, kind: kind)
            guard FileStamp.of(url) == before else { return .success(.pending) }
            return .success(.laidOut(result, before))
        } catch LayoutSourceError.unreadable(_, let reason) {
            guard FileStamp.of(url) == before else { return .success(.pending) }
            return .success(.failed(reason, before))
        } catch {
            return .failure(error)
        }
    }
}
