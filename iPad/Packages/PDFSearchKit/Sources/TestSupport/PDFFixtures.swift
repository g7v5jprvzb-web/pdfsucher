// PDFFixtures.swift — Task 0.3
import CoreGraphics
import CoreText
import Foundation

public enum PDFFixturesError: Error, CustomStringConvertible {
    case cannotCreateContext(URL)
    case textDoesNotFit(page: Int)

    public var description: String {
        switch self {
        case .cannotCreateContext(let url):
            "PDFFixtures: cannot create a PDF context at \(url.path)"
        case .textDoesNotFit(let page):
            "PDFFixtures: text of page \(page) does not fit on one A4 page"
        }
    }
}

public enum PDFFixtures {
    /// A4 portrait in points.
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 50

    /// Writes a PDF whose page i contains pages[i] as real text (Core Text into a PDF context).
    /// Throws `textDoesNotFit` if a page's text would be cut off (12 pt Helvetica, A4).
    public static func makePDF(at url: URL, pages: [String]) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFFixturesError.cannotCreateContext(url)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let textRect = mediaBox.insetBy(dx: margin, dy: margin)
        for (pageIndex, text) in pages.enumerated() {
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.location + visible.length >= attributed.length else {
                context.closePDF()
                try? FileManager.default.removeItem(at: url)
                throw PDFFixturesError.textDoesNotFit(page: pageIndex)
            }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A new, empty, uniquely named directory under `FileManager.default.temporaryDirectory`.
    public static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFSucherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
