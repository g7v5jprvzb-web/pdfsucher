// Models.swift — Task 0.3 (shared types)
import CoreGraphics
import Foundation

public struct ScannedFile: Sendable, Equatable {
    public let relativePath: String
    public let url: URL
    public let fileSize: Int64
    public let modifiedAt: Date

    public init(relativePath: String, url: URL, fileSize: Int64, modifiedAt: Date) {
        self.relativePath = relativePath
        self.url = url
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }

    /// `.pdf` or `.image` by file extension (anything else counts as PDF, as before 1.2).
    public var kind: DocumentKind {
        DocumentKind(fileExtension: (relativePath as NSString).pathExtension) ?? .pdf
    }
}

public enum DocumentStatus: String, Sendable {
    case ok, error, noText = "no_text"
}

public struct StoredDocument: Sendable, Equatable {
    public let id: Int64
    public let relativePath: String
    public let fileSize: Int64
    public let modifiedAt: Date
    public let pageCount: Int
    public let status: DocumentStatus
    public let kind: DocumentKind

    public init(id: Int64, relativePath: String, fileSize: Int64, modifiedAt: Date, pageCount: Int, status: DocumentStatus,
                kind: DocumentKind = .pdf) {
        self.id = id
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.pageCount = pageCount
        self.status = status
        self.kind = kind
    }
}

public enum FTSTable: Sendable {
    case words, trigram
}

public struct RawPageMatch: Sendable, Equatable {
    public let docId: Int64
    public let pageIndex: Int
    public let bm25: Double
    public let text: String

    public init(docId: Int64, pageIndex: Int, bm25: Double, text: String) {
        self.docId = docId
        self.pageIndex = pageIndex
        self.bm25 = bm25
        self.text = text
    }
}

// MARK: OCR (spec 1.2 §12, identical in both OCR branches)

public struct OCRWord: Sendable, Equatable {
  public let range: NSRange        // UTF-16-Bereich im gespeicherten (normalisierten) Seitentext
  public let box: CGRect           // normalisiert 0…1, Ursprung oben links
  public init(range: NSRange, box: CGRect) { self.range = range; self.box = box }
}
public enum DocumentKind: String, Sendable { case pdf, image }

extension DocumentKind {
    /// Image file extensions searched with OCR (spec 1.2 §2), lowercase (`SupportedSourceTypes`).
    public static var imageExtensions: Set<String> { SupportedSourceTypes.imageExtensions }

    /// The kind for a file extension (case-insensitive), nil for files that are not indexed.
    public init?(fileExtension: String) {
        guard let kind = SupportedSourceTypes.kind(forExtension: fileExtension) else { return nil }
        self = kind
    }
}

/// The OCR setting values of spec 1.2 §7 (the settings UI comes later).
public struct OCRSettings: Sendable, Equatable {
    /// „Texterkennung (OCR)“: run phase 2 (scan pages and images).
    public var recognizeText: Bool
    /// „Bilder durchsuchen (PNG, JPEG, HEIC, DNG)“: list image files in folders.
    public var includeImages: Bool

    public init(recognizeText: Bool = true, includeImages: Bool = true) {
        self.recognizeText = recognizeText
        self.includeImages = includeImages
    }

    public static let `default` = OCRSettings()
}

public protocol IndexReading: Sendable {
    func documents() throws -> [StoredDocument]
    func match(_ ftsQuery: String, in table: FTSTable) throws -> [RawPageMatch]
    func allPages() throws -> [RawPageMatch]        // fallback for <3-char partial terms, bm25 = 0
    /// The pages of `match` in batches of `batchSize` (the last may be smaller), in index order: the pages of
    /// one document are contiguous and ascending. `body` returns false to stop (spec 1.1 §5: early results).
    func matchBatches(_ ftsQuery: String, in table: FTSTable, batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws
    /// `allPages` in batches, document by document (pages contiguous and ascending).
    func allPagesBatches(batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws
    /// Recognized word boxes of one page (spec 1.2 §4); empty for pages with a text layer.
    func ocrWords(docId: Int64, pageIndex: Int) throws -> [OCRWord]
}

extension IndexReading {
    /// Readers without OCR data (tests, older fakes) have no word boxes.
    public func ocrWords(docId: Int64, pageIndex: Int) throws -> [OCRWord] { [] }

    /// Default: one `allPages`, cut into batches (for test doubles).
    public func allPagesBatches(batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws {
        try Self.inBatches(try allPages(), batchSize, body)
    }

    static func inBatches(_ all: [RawPageMatch], _ batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws {
        var start = 0
        while start < all.count {
            let end = min(start + max(batchSize, 1), all.count)
            guard try body(Array(all[start..<end])) else { return }
            start = end
        }
    }


    /// Default: one `match`, cut into batches (no early first rows; for test doubles).
    public func matchBatches(_ ftsQuery: String, in table: FTSTable, batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws {
        try Self.inBatches(try match(ftsQuery, in: table), batchSize, body)
    }
}

/// One page waiting for text recognition (phase 2). Size and date identify the file version
/// the job was made for; `IndexStore.storeOCR` ignores a job whose file changed meanwhile.
public struct OCRPageJob: Sendable, Equatable {
    public let docId: Int64
    public let relativePath: String
    public let kind: DocumentKind
    public let pageIndex: Int
    public let fileSize: Int64
    public let modifiedAt: Date

    public init(docId: Int64, relativePath: String, kind: DocumentKind, pageIndex: Int, fileSize: Int64, modifiedAt: Date) {
        self.docId = docId
        self.relativePath = relativePath
        self.kind = kind
        self.pageIndex = pageIndex
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

/// Which indexing phase a progress value belongs to (spec 1.2 §3).
public enum IndexPhase: String, Sendable {
    /// Phase 1: reading the text layer of PDFs.
    case text
    /// Phase 2: text recognition of scan pages and images, counted in pages.
    case ocr
}

public struct IndexProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let currentFile: String?
    public let phase: IndexPhase

    public init(done: Int, total: Int, currentFile: String?, phase: IndexPhase = .text) {
        self.done = done
        self.total = total
        self.currentFile = currentFile
        self.phase = phase
    }
}

/// Outcome of phase 2 (text recognition, spec 1.2 §3, §8).
public struct OCRReport: Sendable, Equatable {
    /// Pages and images on which text was recognized.
    public var recognized = 0
    /// Documents finished in this run in which neither text layer nor OCR found text.
    public var noText: [String] = []
    /// Images that cannot be read (status `error`, „nicht lesbar“).
    public var failed: [String] = []
    /// Pages left for the next run after a recognition error (spec §8 „Vision-Fehler“).
    public var deferred = 0

    public init(recognized: Int = 0, noText: [String] = [], failed: [String] = [], deferred: Int = 0) {
        self.recognized = recognized
        self.noText = noText
        self.failed = failed
        self.deferred = deferred
    }
}

public struct IndexReport: Sendable, Equatable {
    public var added = 0, updated = 0, removed = 0, unchanged = 0
    /// Phase 1: files whose text could not be read.
    public var failed: [String] = []
    /// Phase 1: files without any text and nothing waiting for OCR.
    public var noText: [String] = []
    /// Phase 2 (empty when it did not run).
    public var ocr = OCRReport()

    public init() {}

    public init(added: Int = 0, updated: Int = 0, removed: Int = 0, unchanged: Int = 0, failed: [String] = [], noText: [String] = []) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.unchanged = unchanged
        self.failed = failed
        self.noText = noText
    }
}
