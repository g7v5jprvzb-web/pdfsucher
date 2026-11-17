// SupportedSourceTypes.swift — 1.2.1: the one place that says which files PDFSucher accepts
import Foundation
import UniformTypeIdentifiers

/// File types PDFSucher accepts as sources and indexes in folders. Drop, ⌘O (`openPanelTypes`), the
/// classifier, `FolderScanner` and `ImagePages` all go through here. A new page type (e.g. Word or
/// PowerPoint) adds a `DocumentKind` case, its extensions in `kind(forExtension:)` and its UTTypes.
///
/// 1.3: Word and PowerPoint are accepted only when a caller passes `includeOffice: true` (default
/// false; the app passes its setting „office.include“). The open panel always offers them.
public enum SupportedSourceTypes {
    public static let pdfExtensions: Set<String> = ["pdf"]
    /// Image files searched with text recognition (spec 1.2 §2), lowercase.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "dng"]
    /// iPad (PDF Search): the images it lists and offers (JPEG only).
    public static let iPadImageExtensions: Set<String> = ["jpg", "jpeg"]
    /// Word files (spec 1.3), lowercase. `.doc` is the legacy binary format.
    public static let wordExtensions: Set<String> = ["docx", "docm", "dotx", "doc"]
    /// PowerPoint files (spec 1.3), lowercase. `.ppt` and `.potx` are not supported.
    public static let powerpointExtensions: Set<String> = ["pptx", "pptm"]

    /// The kind for a file extension (case-insensitive), nil for files PDFSucher does not read.
    public static func kind(forExtension fileExtension: String) -> DocumentKind? {
        let ext = fileExtension.lowercased()
        if pdfExtensions.contains(ext) { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if wordExtensions.contains(ext) { return .word }
        if powerpointExtensions.contains(ext) { return .powerpoint }
        return nil
    }

    /// Whether a file with this extension becomes a source or an indexed document. Word and
    /// PowerPoint only with `includeOffice` (spec 1.3; off until Part B wires the UI).
    public static func accepts(fileExtension: String, includeImages: Bool, includeOffice: Bool = false) -> Bool {
        switch kind(forExtension: fileExtension) {
        case .pdf?: true
        case .image?: includeImages
        case .word?, .powerpoint?: includeOffice
        case nil: false
        }
    }

    /// Office lock files (`~$name.docx`) are never documents, whatever their extension.
    public static func isLockFile(name: String) -> Bool { name.hasPrefix("~$") }

    /// `accepts(fileExtension:…)` for a file name, skipping Office lock files.
    public static func accepts(fileName name: String, includeImages: Bool, includeOffice: Bool = false) -> Bool {
        !isLockFile(name: name)
            && accepts(fileExtension: (name as NSString).pathExtension, includeImages: includeImages, includeOffice: includeOffice)
    }

    /// Content types the open panel offers: folders and every accepted file type (images and
    /// Word/PowerPoint always; the classifier ignores them with a hint when their setting is off).
    public static var openPanelTypes: [UTType] {
        let files = (pdfExtensions.sorted() + imageExtensions.sorted() + wordExtensions.sorted() + powerpointExtensions.sorted())
            .compactMap { UTType(filenameExtension: $0) }
        var seen = Set<UTType>()
        return ([.folder] + files).filter { seen.insert($0).inserted }
    }
}
