import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private func tempURL(_ ext: String = "zip") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ooxml-\(UUID().uuidString).\(ext)")
}

private func write(_ data: Data) throws -> URL {
    let url = tempURL()
    try data.write(to: url)
    return url
}

private func sampleBuilder() -> OOXMLBuilder {
    var b = OOXMLBuilder()
    b.add("a.xml", String(repeating: "<a>hello</a>", count: 200), deflate: false)
    b.add("dir/b.xml", String(repeating: "<b>world</b>", count: 200), deflate: true)
    return b
}

private func patch32(_ d: inout Data, centralHeaderOf index: Int = 0, at field: Int, _ v: UInt32) {
    var found = 0
    var i = 0
    while i + 4 <= d.count {
        if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x01, d[i + 3] == 0x02 {
            if found == index {
                for k in 0..<4 { d[i + field + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) }
                return
            }
            found += 1
        }
        i += 1
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ZipArchiveTests {
    @Test func readsStoredAndDeflated() throws {
        let url = try write(sampleBuilder().build())
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(zip.entryNames == ["a.xml", "dir/b.xml"])
        #expect(try zip.data("a.xml") == Data(String(repeating: "<a>hello</a>", count: 200).utf8))
        #expect(try zip.data("dir/b.xml") == Data(String(repeating: "<b>world</b>", count: 200).utf8))
        #expect(zip.contains("a.xml"))
        #expect(!zip.contains("nope.xml"))
    }

    @Test func entryMissing() throws {
        let url = try write(sampleBuilder().build())
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(throws: ZipError.entryMissing("x.xml")) { try zip.data("x.xml") }
        #expect(throws: ZipError.entryMissing("A.xml")) { try zip.data("A.xml") }
    }

    @Test func umlautNamesUTF8() throws {
        var b = OOXMLBuilder()
        b.add("ä.xml", "<x>ü</x>")
        let bytes = b.build()
        // flag bit 11 set in the local header
        #expect(bytes[7] & 0x08 != 0)
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(zip.entryNames == ["ä.xml"])
        #expect(try zip.data("ä.xml") == Data("<x>ü</x>".utf8))
    }

    @Test func nameLookupIsExactNoNormalization() throws {
        var b = OOXMLBuilder()
        b.add("\u{00E4}.xml", "<x/>")  // precomposed
        let url = try write(b.build())
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(zip.contains("\u{00E4}.xml"))
        #expect(!zip.contains("a\u{0308}.xml"))  // decomposed: not the same name
    }

    @Test func oleCompoundDetected() throws {
        let url = try write(OOXMLBuilder.oleCompoundFile())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ZipError.oleCompound) { try ZipArchive(url: url) }
    }

    @Test func truncatedThrows() throws {
        let full = sampleBuilder().build()
        let url = try write(full.dropLast(100))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ZipError.truncated) { try ZipArchive(url: url) }
    }

    @Test func truncatedAtEveryLengthNeverCrashes() throws {
        let full = sampleBuilder().build()
        for n in stride(from: 0, to: full.count, by: 7) {
            let url = try write(full.prefix(n))
            defer { try? FileManager.default.removeItem(at: url) }
            if let zip = try? ZipArchive(url: url) {
                for name in zip.entryNames { _ = try? zip.data(name) }
            }
        }
    }

    @Test func notAZip() throws {
        let url = try write(Data("just some text, not a zip file at all".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ZipError.notAZip) { try ZipArchive(url: url) }
        let empty = try write(Data())
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: ZipError.notAZip) { try ZipArchive(url: empty) }
    }

    @Test func zip64EOCD() throws {
        let url = try write(sampleBuilder().build(zip64: true))
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(zip.entryNames == ["a.xml", "dir/b.xml"])
        #expect(try zip.data("dir/b.xml") == Data(String(repeating: "<b>world</b>", count: 200).utf8))
    }

    @Test func dataDescriptorUsesCentralSizes() throws {
        let url = try write(sampleBuilder().build(dataDescriptors: true))
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(try zip.data("a.xml") == Data(String(repeating: "<a>hello</a>", count: 200).utf8))
        #expect(try zip.data("dir/b.xml").count == 2400)
    }

    @Test func unsupportedMethod() throws {
        var bytes = sampleBuilder().build()
        // central header: method at +10
        var i = 0
        while !(bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 1 && bytes[i + 3] == 2) { i += 1 }
        bytes[i + 10] = 99
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(throws: ZipError.unsupportedMethod(99)) { try zip.data("a.xml") }
    }

    @Test func hostileSizesAreRejected() throws {
        // deflated entry (index 1): claim 4 GB uncompressed
        var bytes = sampleBuilder().build()
        patch32(&bytes, centralHeaderOf: 1, at: 24, 0xFFFF_FFF0)
        var urls: [URL] = []
        defer { for u in urls { try? FileManager.default.removeItem(at: u) } }
        var url = try write(bytes)
        urls.append(url)
        var zip = try ZipArchive(url: url)
        #expect(throws: ZipError.self) { try zip.data("dir/b.xml") }
        // compressed size beyond end of file
        bytes = sampleBuilder().build()
        patch32(&bytes, centralHeaderOf: 0, at: 20, 0x7FFF_0000)
        url = try write(bytes)
        urls.append(url)
        zip = try ZipArchive(url: url)
        #expect(throws: ZipError.self) { try zip.data("a.xml") }
        // local offset beyond end of file
        bytes = sampleBuilder().build()
        patch32(&bytes, centralHeaderOf: 0, at: 42, 0xFFFF_0000)
        url = try write(bytes)
        urls.append(url)
        zip = try ZipArchive(url: url)
        #expect(throws: ZipError.self) { try zip.data("a.xml") }
    }

    /// Audit 2026-11-15: a deflated entry whose directory claims fewer bytes than the stream holds is rejected,
    /// not cut off at the claimed size; `maxSize` lowers the limit per call.
    @Test func understatedSizeIsRejectedAndMaxSizeApplies() throws {
        var bytes = sampleBuilder().build()
        let full = String(repeating: "<b>world</b>", count: 200).utf8.count
        patch32(&bytes, centralHeaderOf: 1, at: 24, UInt32(full - 10))
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(throws: ZipError.self) { try zip.data("dir/b.xml") }

        let ok = try ZipArchive(data: sampleBuilder().build())
        #expect(try ok.data("dir/b.xml", maxSize: UInt64(full)).count == full)
        #expect(throws: ZipError.self) { try ok.data("dir/b.xml", maxSize: UInt64(full - 1)) }
    }

    @Test func randomGarbageNeverCrashes() throws {
        let seed = ProcessInfo.processInfo.environment["OOXML_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x5EED_0001
        var rng = SplitMix64(seed: seed)
        let base = sampleBuilder().build()
        for _ in 0..<200 {
            var d = base
            for _ in 0..<8 { d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            let url = try write(d)
            defer { try? FileManager.default.removeItem(at: url) }
            if let zip = try? ZipArchive(url: url) {
                for name in zip.entryNames { _ = try? zip.data(name) }
            }
        }
    }

    @Test func lazyRead() throws {
        var b = OOXMLBuilder()
        b.addData("filler.bin", Data(count: 50 * 1024 * 1024), deflate: false)
        b.add("small.xml", "<small/>", deflate: false)
        let url = try write(b.build())
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ContinuousClock()
        var zip: ZipArchive?
        let initTime = try clock.measure { zip = try ZipArchive(url: url) }
        #expect(initTime < .milliseconds(50), "init took \(initTime)")
        var small: Data?
        let readTime = clock.measure { small = try? zip?.data("small.xml") }
        #expect(small == Data("<small/>".utf8))
        #expect(readTime < .milliseconds(50), "small read took \(readTime)")
    }

    @Test func fakeEOCDInsideCommentIsSkipped() throws {
        var b = sampleBuilder()
        var comment = Data(repeating: 0x41, count: 3000)
        // fake EOCD signature followed by zeros (entry count 0) in the middle of the comment
        comment.replaceSubrange(1000..<1004, with: [0x50, 0x4B, 0x05, 0x06])
        for i in 1004..<1022 { comment[i] = 0 }
        b.comment = comment
        let url = try write(b.build())
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(zip.entryNames == ["a.xml", "dir/b.xml"])
    }

    @Test func implausibleRatioRejected() throws {
        var bytes = sampleBuilder().build()
        patch32(&bytes, centralHeaderOf: 1, at: 24, 100 * 1024 * 1024)  // 100 MB claimed from a tiny stream
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let zip = try ZipArchive(url: url)
        #expect(throws: ZipError.self) { try zip.data("dir/b.xml") }
        do { _ = try zip.data("dir/b.xml") } catch {
            guard case .corrupt(let m) = error else { Issue.record("wrong error \(error)"); return }
            #expect(m.contains("implausible"))
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"), "/usr/bin/zip not available"))
    func readsZipProducedBySystemZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ooxml-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let deflated = String(repeating: "deflate me ", count: 500)
        try deflated.write(to: dir.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try "stored".write(to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out.zip")
        func zip(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-q"] + args
            p.currentDirectoryURL = dir
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        try zip(["-6", out.path, "d.txt"])
        try zip(["-0", out.path, "s.txt"])
        let archive = try ZipArchive(url: out)
        #expect(archive.entryNames == ["d.txt", "s.txt"])
        #expect(try archive.data("d.txt") == Data(deflated.utf8))
        #expect(try archive.data("s.txt") == Data("stored".utf8))
    }
}
