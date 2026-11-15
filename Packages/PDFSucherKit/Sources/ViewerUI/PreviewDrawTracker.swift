// PreviewDrawTracker.swift — 1.3.4 Vorschau-Puffer
import Foundation
import os
import PDFKit
import Synchronization

/// Tells when the large preview's PDFView has drawn a page (spec 1.3.4: the stand-in picture stays until the
/// PDFView has drawn the page sharply).
///
/// A preview document gets this object as its delegate before any page is read, so PDFKit makes its pages
/// `TrackedPage`s; each of their draws reports the page and the scale of the context it drew into (on PDFKit's
/// drawing threads). The document does not keep its delegate: `DetailDocument` holds this object.
final class PreviewDrawTracker: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    private let handler = Mutex<(@Sendable (ObjectIdentifier, CGFloat) -> Void)?>(nil)

    /// Called after every draw of a page of the document: the page's identity and the context's scale
    /// (device pixels per page point). Called on any thread.
    var onDraw: (@Sendable (ObjectIdentifier, CGFloat) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    func classForPage() -> AnyClass { TrackedPage.self }

    fileprivate func drew(_ page: PDFPage, scale: CGFloat) {
        handler.withLock { $0 }?(ObjectIdentifier(page), scale)
    }
}

/// A page of a preview document: reports its draws to the document's `PreviewDrawTracker`.
final class TrackedPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        let ctm = context.ctm
        (document?.delegate as? PreviewDrawTracker)?.drew(self, scale: (ctm.a * ctm.a + ctm.b * ctm.b).squareRoot())
    }
}
