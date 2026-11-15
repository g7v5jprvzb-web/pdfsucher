// Printer.swift — Task 3.2
import AppKit
import Foundation
import PDFKit

@MainActor public enum Printer {
    /// A print operation for the merged pages; run it (e.g. `runModal(for:…)`) to show the macOS print dialog.
    /// The caller may set `jobTitle` (e.g. from `DefaultFileName`, without ".pdf") for "Save as PDF".
    /// Merges on the main actor: fine for a few PDF pages, but with Office pages (`foreign`: Word layout, slide
    /// decoding) build the document with `PrintDocument.build(_:foreign:)` in a background task and pass it to
    /// `printOperation(for: document)` instead.
    public static func printOperation(for refs: [PageRef], foreign: (any ForeignPageProvider)? = nil) throws -> NSPrintOperation {
        printOperation(for: try Merger(foreign: foreign).makeDocument(refs))
    }

    /// A print operation for an already merged document (built off the main actor, see `PrintDocument`).
    public static func printOperation(for document: PDFDocument) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation: NSPrintOperation
        if let pdfOperation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) {
            operation = pdfOperation
        } else {
            // Not observed for a fresh, unlocked document; fall back to printing a PDFView.
            outputLog.error("PDFDocument.printOperation returned nil; using PDFView fallback")
            let view = PDFView(frame: NSRect(origin: .zero, size: info.paperSize))
            view.document = document
            view.autoScales = true
            operation = NSPrintOperation(view: view, printInfo: info)
        }
        operation.jobTitle = "Auswahl"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }
}

/// A merged document handed from the background task that built it to the main actor, which prints
/// it. `PDFDocument` is not `Sendable`; the builder keeps no reference after handing it over.
public struct PrintDocument: @unchecked Sendable {
    public let document: PDFDocument

    /// Merges `refs` (call off the main actor; throws like `Merger.makeDocument`).
    public static func build(_ refs: [PageRef], foreign: (any ForeignPageProvider)? = nil) throws -> PrintDocument {
        PrintDocument(document: try Merger(foreign: foreign).makeDocument(refs))
    }
}
