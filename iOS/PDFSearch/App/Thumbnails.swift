import PDFKit
import PDFSearchCore
import SwiftUI
import UIKit

/// Renders and caches page and photo thumbnails off the main thread.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let images = NSCache<NSString, UIImage>()
    /// PDFKit documents are not thread-safe: every render holds this lock.
    private let lock = NSLock()
    private var documents: [URL: PDFDocument] = [:]
    private var documentOrder: [URL] = []

    init() {
        images.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(url: URL, kind: FileKind, page: Int, maxPixel: Int) -> UIImage? {
        images.object(forKey: Self.key(url, page, maxPixel) as NSString)
    }

    func image(url: URL, kind: FileKind, page: Int, maxPixel: Int) async -> UIImage? {
        let key = Self.key(url, page, maxPixel) as NSString
        if let hit = images.object(forKey: key) { return hit }
        let rendered = await Task.detached(priority: .userInitiated) { [self] in
            ImageBox(image: self.render(url: url, kind: kind, page: page, maxPixel: maxPixel))
        }.value
        if let image = rendered.image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            images.setObject(image, forKey: key, cost: cost)
        }
        return rendered.image
    }

    private static func key(_ url: URL, _ page: Int, _ maxPixel: Int) -> String {
        "\(url.path)#\(page)@\(maxPixel)"
    }

    private func render(url: URL, kind: FileKind, page: Int, maxPixel: Int) -> UIImage? {
        switch kind {
        case .jpeg:
            return (try? ImageLoading.cgImage(at: url, maxPixelSize: maxPixel)).map { UIImage(cgImage: $0) }
        case .pdf:
            lock.lock()
            defer { lock.unlock() }
            guard let document = document(for: url), let pdfPage = document.page(at: page - 1),
                  let cgImage = PageRendering.cgImage(of: pdfPage, maxPixelSize: CGFloat(maxPixel)) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }

    /// Called with `lock` held. Keeps the last few documents open.
    private func document(for url: URL) -> PDFDocument? {
        if let open = documents[url] { return open }
        guard let opened = PDFDocument(url: url) else { return nil }
        documents[url] = opened
        documentOrder.append(url)
        if documentOrder.count > 6 {
            documents[documentOrder.removeFirst()] = nil
        }
        return opened
    }
}

private struct ImageBox: @unchecked Sendable {
    let image: UIImage?
}

/// A page or photo thumbnail that loads itself.
struct ThumbnailImage: View {
    let url: URL?
    let kind: FileKind
    let page: Int
    let maxPixel: Int

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: kind == .jpeg ? .fill : .fit)
            } else {
                Rectangle().fill(Color(.secondarySystemBackground))
            }
        }
        .task(id: taskID) {
            guard let url else { return }
            image = ThumbnailCache.shared.cached(url: url, kind: kind, page: page, maxPixel: maxPixel)
            if image == nil {
                image = await ThumbnailCache.shared.image(url: url, kind: kind, page: page, maxPixel: maxPixel)
            }
        }
    }

    private var taskID: String { "\(url?.path ?? "")#\(page)@\(maxPixel)" }
}
