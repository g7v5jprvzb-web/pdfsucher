// pdfkit-process-bench.swift — does PDFKit slow down inside one process? (index-speed, 2026-11-16)
//
//   swiftc -O scripts/pdfkit-process-bench.swift -o /tmp/pdfkit-bench
//   /tmp/pdfkit-bench <sample.txt> <threads> [<shard> <shards>]
//
// Reads the PDFs listed in sample.txt (one absolute path per line; with shard/shards only every shards-th file starting
// at shard), extracting the text of every page with `threads` threads like PDFKitTextSource (PDFPage.string; without
// TextNormalizer). Prints numbers only: files, pages, wall and summed seconds.
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count >= 3, let threads = Int(args[2]) else {
    print("usage: pdfkit-bench <sample.txt> <threads> [<shard> <shards>]"); exit(2)
}
let shard = args.count >= 5 ? Int(args[3])! : 0, shards = args.count >= 5 ? Int(args[4])! : 1
let all = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").map(String.init)
let files = all.enumerated().filter { $0.offset % shards == shard }.map(\.element)

let lock = NSLock()
var next = 0, pages = 0, sum = 0.0
let start = Date()
let group = DispatchGroup()
for _ in 0..<threads {
    group.enter()
    Thread {
        while true {
            lock.lock(); let i = next; next += 1; lock.unlock()
            guard i < files.count else { break }
            let t = Date()
            var n = 0
            autoreleasepool {
                if let doc = PDFDocument(url: URL(fileURLWithPath: files[i])) {
                    for p in 0..<doc.pageCount { autoreleasepool { _ = doc.page(at: p)?.string; n += 1 } }
                }
            }
            let s = Date().timeIntervalSince(t)
            lock.lock(); pages += n; sum += s; lock.unlock()
        }
        group.leave()
    }.start()
}
group.wait()
let wall = Date().timeIntervalSince(start)
print(String(format: "PROC shard=%d/%d threads=%d files=%d pages=%d wall=%.2fs sum=%.2fs", shard, shards, threads, files.count, pages, wall, sum))
