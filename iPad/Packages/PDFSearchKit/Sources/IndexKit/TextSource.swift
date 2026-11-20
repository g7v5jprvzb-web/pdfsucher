// TextSource.swift — Task 0.3 (shared types)
import Foundation

public struct PageText: Sendable, Equatable {
    public let pageIndex: Int
    public let text: String
    /// The page still needs text recognition (phase 2, spec 1.2 §3): a PDF page whose text
    /// layer has fewer than `OCRPolicy.minimumTextLength` characters, or an image.
    public let needsOCR: Bool

    public init(pageIndex: Int, text: String, needsOCR: Bool = false) {
        self.pageIndex = pageIndex
        self.text = text
        self.needsOCR = needsOCR
    }
}

public protocol TextSource: Sendable {
    func pages(of url: URL) throws -> [PageText]
}
