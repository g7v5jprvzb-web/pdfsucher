import Foundation
import MediaKit
import PDFKit
import UIKit

/// Renders page thumbnails off the main thread and keeps them in memory.
actor Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, UIImage>()
    private var documents: [URL: PDFDocument] = [:]
    private var documentOrder: [URL] = []

    init() { cache.countLimit = 600 }

    /// `pixel` is the longer side in pixels.
    func image(url: URL, page: Int, isImage: Bool, pixel: Int) -> UIImage? {
        let key = "\(url.path)#\(page)#\(pixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made: UIImage?
        if isImage {
            made = ImageThumbnails.thumbnail(for: url, maxPixel: pixel).map { UIImage(cgImage: $0) }
        } else if let doc = document(url), let pdfPage = doc.page(at: page) {
            let bounds = pdfPage.bounds(for: .cropBox)
            let scale = CGFloat(pixel) / max(bounds.width, bounds.height, 1)
            made = pdfPage.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
        } else {
            made = nil
        }
        if let made { cache.setObject(made, forKey: key) }
        return made
    }

    private func document(_ url: URL) -> PDFDocument? {
        if let doc = documents[url] { return doc }
        guard let doc = PDFDocument(url: url) else { return nil }
        documents[url] = doc
        documentOrder.append(url)
        if documentOrder.count > 24 { documents[documentOrder.removeFirst()] = nil }
        return doc
    }
}
