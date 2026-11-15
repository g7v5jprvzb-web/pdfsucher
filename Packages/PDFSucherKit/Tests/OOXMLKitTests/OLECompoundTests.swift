import Foundation
import Testing
import TestSupport
@testable import OOXMLKit

private func write(_ data: Data, ext: String = "bin") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ole-\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
}

@Suite struct OLECompoundTests {
    @Test func encryptedOOXMLStreams() throws {
        let url = try write(CFBBuilder.file(streams: ["EncryptionInfo", "EncryptedPackage"]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try OLECompound.streamNames(url: url) == ["Root Entry", "EncryptionInfo", "EncryptedPackage"])
        #expect(OLECompound.isEncryptedOOXML(url: url))
    }

    @Test func encryptedPackageAloneCounts() throws {
        let url = try write(CFBBuilder.file(streams: ["EncryptedPackage"]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(OLECompound.isEncryptedOOXML(url: url))
    }

    @Test func legacyBinaryFilesAreNotEncryptedOOXML() throws {
        for streams in [["WordDocument", "1Table"], ["PowerPoint Document", "Current User", "Pictures"]] {
            let url = try write(CFBBuilder.file(streams: streams))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try OLECompound.streamNames(url: url) == ["Root Entry"] + streams)
            #expect(!OLECompound.isEncryptedOOXML(url: url))
        }
    }

    @Test func directorySpanningSeveralSectors() throws {
        let streams = ["A", "B", "C", "D", "E", "F", "G", "EncryptionInfo"]   // 9 entries → 3 sectors
        let url = try write(CFBBuilder.file(streams: streams))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try OLECompound.streamNames(url: url) == ["Root Entry"] + streams)
    }

    @Test func cyclicDirectoryChainTerminates() throws {
        // sector 1 → 2 → 1 → …: each sector is read once.
        let url = try write(CFBBuilder.file(streams: ["A", "B", "C", "D", "E"], directoryChain: [2, 1]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try OLECompound.streamNames(url: url) == ["Root Entry", "A", "B", "C", "D", "E"])
    }

    @Test func badDirectorySectorFallsBackToByteScan() throws {
        let data = CFBBuilder.file(streams: ["EncryptionInfo"], firstDirectorySector: 9999)
        let url = try write(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: OLECompoundError.self) { try OLECompound.streamNames(url: url) }
        #expect(OLECompound.isEncryptedOOXML(url: url))

        let plain = try write(CFBBuilder.file(streams: ["PowerPoint Document"], firstDirectorySector: 9999))
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(!OLECompound.isEncryptedOOXML(url: plain))
    }

    @Test func signatureOnlyFile() throws {
        let url = try write(OOXMLBuilder.oleCompoundFile())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: OLECompoundError.self) { try OLECompound.streamNames(url: url) }
        #expect(!OLECompound.isEncryptedOOXML(url: url))
    }

    @Test func notOLE() throws {
        let url = try write(Data("PK\u{3}\u{4}hello".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: OLECompoundError.notOLE) { try OLECompound.streamNames(url: url) }
        #expect(!OLECompound.isEncryptedOOXML(url: url))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ole-missing-\(UUID().uuidString)")
        #expect(!OLECompound.isEncryptedOOXML(url: missing))
    }

    @Test func truncatedAndGarbageNeverCrash() throws {
        let full = CFBBuilder.file(streams: ["EncryptionInfo", "EncryptedPackage"])
        for n in stride(from: 8, to: full.count, by: 37) {
            _ = try? OLECompound.streamNames(data: full.prefix(n))
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var d = full
            for _ in 0..<8 { d[Int.random(in: 8..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? OLECompound.streamNames(data: d)
        }
    }
}
