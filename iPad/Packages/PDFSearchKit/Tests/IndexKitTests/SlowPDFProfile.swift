import CryptoKit
import Foundation
import IndexKit
import PDFKit
import Testing

/// Opt-in (1.4.0 P6): where the time of single slow PDFs goes. Reads the files listed (one path per line) in
/// `PDFSUCHER_SLOW_PDFS`; prints hashes and numbers only, never names or text.
@Suite("Langsame PDFs profilieren")
struct SlowPDFProfile {
    static let list = ProcessInfo.processInfo.environment["PDFSUCHER_SLOW_PDFS"]

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    @Test(.enabled(if: list != nil), .timeLimit(.minutes(30)))
    func profile() throws {
        let paths = try String(contentsOfFile: Self.list!, encoding: .utf8).split(separator: "\n").map(String.init)
        print("PROFILE hash          MB  pages  open_ms  string_ms  max_page_ms  normalize_ms  chars_k  empty_pages  total_ms(source)")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let hash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let mb = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1e6
            var t = ContinuousClock.now
            guard let doc = PDFDocument(url: url) else { print("PROFILE \(hash) unreadable"); continue }
            let open = Self.ms(.now - t)
            var stringMs = 0.0, maxPage = 0.0, normalizeMs = 0.0, chars = 0, empty = 0
            for i in 0..<doc.pageCount {
                autoreleasepool {
                    t = .now
                    let text = doc.page(at: i)?.string ?? ""
                    let pageMs = Self.ms(.now - t)
                    stringMs += pageMs
                    maxPage = max(maxPage, pageMs)
                    t = .now
                    let normalized = TextNormalizer.normalize(text)
                    normalizeMs += Self.ms(.now - t)
                    chars += normalized.count
                    if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
                }
            }
            t = .now
            _ = try? PDFKitTextSource().pages(of: url)
            let total = Self.ms(.now - t)
            print(String(format: "PROFILE %@ %6.1f %6d %8.0f %10.0f %12.0f %13.0f %8d %12d %10.0f", hash, mb, doc.pageCount, open, stringMs,
                         maxPage, normalizeMs, chars / 1000, empty, total))
        }
    }
}
