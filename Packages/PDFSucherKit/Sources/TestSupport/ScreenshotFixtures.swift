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

    /// Office screenshots (1.3 Teil B): one contract PDF, a 3-page Word document and a 4-slide deck (slide 3
    /// hidden), all with „Kündigungsfrist“ on a later page/slide (the hidden slide has it too, it must not be a hit).
    /// Invented texts only.
    public static func makeOffice(in folder: URL) throws {
        let filler = "Die Parteien regeln Laufzeit, Kündigung und Haftung. Änderungen bedürfen der Schriftform."
        let contracts = folder.appendingPathComponent("Verträge", isDirectory: true)
        let decks = folder.appendingPathComponent("Präsentationen", isDirectory: true)
        try FileManager.default.createDirectory(at: contracts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decks, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: contracts.appendingPathComponent("Mietvertrag_Buero_2024.pdf"), pages: [
            "Mietvertrag Büro\n\n§ 1 Mietsache\n\nVermietet werden Büroräume im 2. Obergeschoss. \(filler)",
            "§ 5 Kündigungsfrist\n\nDie Kündigungsfrist beträgt sechs Monate zum Jahresende. \(filler)",
            "§ 6 Übergabe\n\nDie Räume werden besenrein übergeben. \(filler)",
        ])
        try OfficeFixtures.docx(paragraphs: [
            "Rahmenvertrag über IT-Leistungen",
            "§ 1 Gegenstand: Der Auftragnehmer erbringt Wartung und Betreuung der Arbeitsplätze. \(filler)",
            "§ 2 Laufzeit und Kündigungsfrist",
            "Der Vertrag läuft zwei Jahre. Die Kündigungsfrist beträgt drei Monate zum Quartalsende. \(filler)",
            "§ 3 Haftung und Gewährleistung",
            "Die Haftung ist auf grobe Fahrlässigkeit begrenzt. Größe, Straße, Übung. \(filler)",
        ], pageBreakAfter: [1, 3], name: "Rahmenvertrag.docx", in: contracts)
        try OfficeFixtures.pptx(slides: [
            "Vertragsübersicht 2024\nStand Januar",
            "Kündigungsfrist\nDrei Monate zum Quartalsende\nSchriftform erforderlich",
            "Interne Notizen\nKündigungsfrist intern prüfen",
            "Nächste Schritte\nVerlängerung prüfen",
        ], hidden: [2], name: "Vertragsübersicht.pptx", in: decks)
    }
}
