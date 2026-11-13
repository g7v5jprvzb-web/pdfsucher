// SupportedSourceTypes.swift — 1.2.1: the one place that says which files PDFSucher accepts
import Foundation
import UniformTypeIdentifiers

/// File types PDFSucher accepts as sources and indexes in folders. Drop, ⌘O (`openPanelTypes`), the
/// classifier, `FolderScanner` and `ImagePages` all go through here. A new page type (e.g. Word or
/// PowerPoint) adds a `DocumentKind` case, its extensions in `kind(forExtension:)` and its UTTypes.
public enum SupportedSourceTypes {
    public static let pdfExtensions: Set<String> = ["pdf"]
    /// Image files searched with text recognition (spec 1.2 §2), lowercase.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "dng"]

    /// The kind for a file extension (case-insensitive), nil for files PDFSucher does not read.
    public static func kind(forExtension fileExtension: String) -> DocumentKind? {
        let ext = fileExtension.lowercased()
        if pdfExtensions.contains(ext) { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// Whether a file with this extension becomes a source or an indexed document.
    public static func accepts(fileExtension: String, includeImages: Bool) -> Bool {
        switch kind(forExtension: fileExtension) {
        case .pdf?: true
        case .image?: includeImages
        case nil: false
        }
    }

    /// Content types the open panel offers: folders and every accepted file type (images always; the
    /// classifier ignores them with a hint when „Bilder durchsuchen“ is off).
    public static var openPanelTypes: [UTType] {
        let files = (pdfExtensions.sorted() + imageExtensions.sorted()).compactMap { UTType(filenameExtension: $0) }
        var seen = Set<UTType>()
        return ([.folder] + files).filter { seen.insert($0).inserted }
    }
}
