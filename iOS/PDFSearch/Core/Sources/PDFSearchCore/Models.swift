import Foundation

/// File types the iPhone app indexes. Word and PowerPoint are deliberately not supported.
public enum FileKind: String, Sendable, CaseIterable, Codable, Hashable {
    case pdf
    case jpeg

    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "jpg", "jpeg": self = .jpeg
        default: return nil
        }
    }
}

/// A folder the user picked in the Files app.
public struct FolderRecord: Sendable, Hashable, Identifiable {
    public let id: Int64
    public var name: String
    /// Security-scoped bookmark (created while access was granted).
    public var bookmark: Data
    public var addedAt: Date

    public init(id: Int64, name: String, bookmark: Data, addedAt: Date) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.addedAt = addedAt
    }
}

public enum FileState: String, Sendable, Hashable {
    /// Text was read; pages are searchable.
    case indexed
    /// Cloud placeholder (iCloud, OneDrive …) that is not on the device yet.
    case notDownloaded
    /// The file could not be read (damaged, password-protected …).
    case failed
}

/// One file as stored in the index.
public struct StoredFile: Sendable, Hashable {
    public let id: Int64
    public let folderID: Int64
    public let relativePath: String
    public let kind: FileKind
    public let size: Int64
    public let modified: Double
    public let pageCount: Int
    public let state: FileState
}

/// Counts shown in the library.
public struct FolderStats: Sendable, Hashable {
    public var pdfCount = 0
    public var jpegCount = 0
    public var notDownloaded = 0
    public var failed = 0

    public init(pdfCount: Int = 0, jpegCount: Int = 0, notDownloaded: Int = 0, failed: Int = 0) {
        self.pdfCount = pdfCount
        self.jpegCount = jpegCount
        self.notDownloaded = notDownloaded
        self.failed = failed
    }
}

/// Where to search.
public enum SearchScope: Sendable, Hashable {
    /// Every folder the app has access to ("Ganzes iPhone").
    case everywhere
    case folder(Int64)
}

public enum SortOrder: String, Sendable, CaseIterable, Hashable {
    case hits
    case name
    case modified

    public var title: String {
        switch self {
        case .hits: "Trefferanzahl"
        case .name: "Name"
        case .modified: "Zuletzt geändert"
        }
    }
}

public struct SearchRequest: Sendable, Hashable {
    public var text: String
    public var scope: SearchScope
    public var kinds: Set<FileKind>
    public var sort: SortOrder

    public init(text: String, scope: SearchScope = .everywhere, kinds: Set<FileKind> = Set(FileKind.allCases), sort: SortOrder = .hits) {
        self.text = text
        self.scope = scope
        self.kinds = kinds
        self.sort = sort
    }
}

public struct PageHit: Sendable, Hashable {
    /// 1-based page number (always 1 for a JPEG).
    public let number: Int
    public let count: Int

    public init(number: Int, count: Int) {
        self.number = number
        self.count = count
    }
}

/// All hits in one file.
public struct DocumentHit: Sendable, Hashable, Identifiable {
    public let fileID: Int64
    public let folderID: Int64
    public let relativePath: String
    public let kind: FileKind
    public let modified: Double
    public let pageCount: Int
    /// Hit pages in page order.
    public let pages: [PageHit]

    public var id: Int64 { fileID }
    public var totalHits: Int { pages.reduce(0) { $0 + $1.count } }
    public var name: String { (relativePath as NSString).lastPathComponent }
    /// Folder path inside the picked folder ("" at its top level).
    public var subfolder: String { (relativePath as NSString).deletingLastPathComponent }
    public var hitPageNumbers: [Int] { pages.map(\.number) }

    public init(fileID: Int64, folderID: Int64, relativePath: String, kind: FileKind, modified: Double, pageCount: Int, pages: [PageHit]) {
        self.fileID = fileID
        self.folderID = folderID
        self.relativePath = relativePath
        self.kind = kind
        self.modified = modified
        self.pageCount = pageCount
        self.pages = pages
    }
}

public struct SearchResult: Sendable, Hashable {
    public var documents: [DocumentHit]
    /// Folded search terms, for highlighting.
    public var terms: [String]

    public init(documents: [DocumentHit], terms: [String]) {
        self.documents = documents
        self.terms = terms
    }

    public static let empty = SearchResult(documents: [], terms: [])

    public var pdfDocuments: [DocumentHit] { documents.filter { $0.kind == .pdf } }
    public var photos: [DocumentHit] { documents.filter { $0.kind == .jpeg } }
    public var pdfHitPageCount: Int { pdfDocuments.reduce(0) { $0 + $1.pages.count } }
}
