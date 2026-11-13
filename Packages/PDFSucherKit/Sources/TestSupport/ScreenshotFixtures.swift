// ScreenshotFixtures.swift — Task 5.5: a small, realistic folder for screenshots and UI tests
import Foundation

public enum ScreenshotFixtures {
    /// Five contracts with many „Vertrag“ hit pages in subfolders, plus one page where
    /// „Miet-“ / „vertrag“ is split across a line break.
    public static func make(in folder: URL) throws {
        let filler = "Die Parteien regeln Laufzeit, Kündigung und Haftung. Änderungen bedürfen der Schriftform."
        let documents: [(String, Int, Set<Int>)] = [
            ("Verträge/Mietvertrag_Buero_2024.pdf", 16, [0, 1, 3, 4, 6, 7, 9, 11, 12, 14]),
            ("Verträge/Rahmenvertrag_IT.pdf", 12, [0, 2, 3, 5, 8, 9, 10]),
            ("Angebote/Angebot_Mueller.pdf", 8, [1, 4, 6]),
            ("Archiv/Wartungsvertrag_2019.pdf", 10, [0, 1, 2, 3, 4, 5, 6, 7]),
            ("Archiv/Kaufvertrag_Fahrzeug.pdf", 6, [2, 5]),
        ]
        for (path, pageCount, hitPages) in documents {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pages = (0..<pageCount).map { i in
                hitPages.contains(i)
                    ? "Seite \(i + 1)\n\n§ \(i + 1) Vertrag\n\nDer Vertrag tritt am 1. Januar in Kraft. \(filler)\n\nDieser Vertrag ersetzt alle früheren Vereinbarungen. \(filler)"
                    : "Seite \(i + 1)\n\nAllgemeine Angaben. \(filler)\n\n\(filler)"
            }
            try PDFFixtures.makePDF(at: url, pages: pages)
        }
        let protocolURL = folder.appendingPathComponent("Getrennt/Uebergabeprotokoll.pdf")
        try FileManager.default.createDirectory(at: protocolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: protocolURL, pages: [
            "Übergabeprotokoll\n\nDie Wohnung wurde gemäß dem Miet-\nvertrag vom 1. März übergeben.\n\n\(filler)",
        ])
    }
}
