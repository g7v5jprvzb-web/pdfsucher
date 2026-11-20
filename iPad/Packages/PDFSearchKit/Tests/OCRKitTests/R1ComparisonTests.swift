// R1 (spec 1.2 §11): classic text recognition vs. document recognition on macOS 26.
// Only runs with PDFSUCHER_R1=1; prints a comparison table for docs/decisions.md.
import CoreGraphics
import Foundation
import Testing
import TestSupport
import Vision

@Suite("R1 Vision API comparison", .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_R1"] == "1"))
struct R1ComparisonTests {
    struct Sample { let name: String; let lines: [String]; let fontSize: CGFloat; let size: CGSize }

    static let samples: [Sample] = [
        Sample(name: "Deutsch 64pt", lines: ["Der Prüfungsergebnis-Bericht für Müller", "enthält Änderungen über Größe und Maß."],
               fontSize: 64, size: CGSize(width: 1600, height: 500)),
        Sample(name: "Englisch 64pt", lines: ["The quarterly invoice shows", "outstanding payments overdue."],
               fontSize: 64, size: CGSize(width: 1600, height: 500)),
        Sample(name: "Deutsch 18pt", lines: (0..<12).map { i in "Zeile \(i): Kündigungsfrist beträgt drei Monate zum Quartalsende, schriftlich." },
               fontSize: 18, size: CGSize(width: 1240, height: 600)),
        Sample(name: "Zwei Spalten", lines: (0..<8).map { i in "Vertragsnummer \(i) Übergabe      Rechnungsbetrag \(i) Fälligkeit" },
               fontSize: 32, size: CGSize(width: 1600, height: 900)),
    ]

    static func words(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func accuracy(expected: [String], got: String) -> Double {
        var bag = Dictionary(words(got).map { ($0, 1) }, uniquingKeysWith: +)
        var hits = 0
        for w in expected { if let n = bag[w], n > 0 { hits += 1; bag[w] = n - 1 } }
        return Double(hits) / Double(max(expected.count, 1))
    }

    @Test func compareAPIs() async throws {
        let languages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        var rows: [String] = ["| Bild | API | Wörter richtig | Zeit | Wortrahmen |", "|---|---|---|---|---|"]
        for sample in Self.samples {
            let (image, _) = try OCRFixtures.textImage(sample.lines, size: sample.size, fontSize: sample.fontSize)
            let expected = Self.words(sample.lines.joined(separator: " "))

            var text = RecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.recognitionLanguages = languages
            text.usesLanguageCorrection = true
            var start = ContinuousClock.now
            let lines = try await text.perform(on: image)
            let textTime = ContinuousClock.now - start
            let textString = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            var boxes = 0
            for line in lines {
                guard let candidate = line.topCandidates(1).first else { continue }
                let s = candidate.string
                for r in s.split(separator: " ") where candidate.boundingBox(for: r.startIndex..<r.endIndex) != nil { boxes += 1 }
            }
            rows.append("| \(sample.name) | RecognizeTextRequest | \(String(format: "%.0f %%", 100 * Self.accuracy(expected: expected, got: textString))) | \(textTime) | \(boxes) Wörter |")

            var doc = RecognizeDocumentsRequest()
            doc.textRecognitionOptions.recognitionLanguages = languages
            doc.textRecognitionOptions.useLanguageCorrection = true
            start = ContinuousClock.now
            let docs = try await doc.perform(on: image)
            let docTime = ContinuousClock.now - start
            let docString = docs.map { $0.document.text.transcript }.joined(separator: "\n")
            let docWords = docs.reduce(0) { $0 + ($1.document.text.words?.count ?? 0) }
            rows.append("| \(sample.name) | RecognizeDocumentsRequest | \(String(format: "%.0f %%", 100 * Self.accuracy(expected: expected, got: docString))) | \(docTime) | \(docWords) Wörter |")
            let vn = VNRecognizeTextRequest()
            vn.recognitionLevel = .accurate
            vn.recognitionLanguages = ["de-DE", "en-US"]
            vn.usesLanguageCorrection = true
            start = ContinuousClock.now
            try VNImageRequestHandler(cgImage: image).perform([vn])
            let vnTime = ContinuousClock.now - start
            let vnString = (vn.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            rows.append("| \(sample.name) | VNRecognizeTextRequest (rev \(vn.revision)) | \(String(format: "%.0f %%", 100 * Self.accuracy(expected: expected, got: vnString))) | \(vnTime) | same as RecognizeText: \(vnString == textString) |")
            print("R1 \(sample.name)\n  text: \(textString.debugDescription)\n  docs: \(docString.debugDescription)")
        }
        print(rows.joined(separator: "\n"))
    }
}
