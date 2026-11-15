// OLECompound.swift — Task 8 (SlideKit, shared with WordKit)
// Minimal OLE compound file (CFB) probe: lists directory entry names to tell encrypted OOXML
// (streams "EncryptionInfo"/"EncryptedPackage") from legacy binary Office files (.ppt/.doc/.xls).
// Reads only the header, the FAT sectors (header DIFAT + DIFAT chain) and the directory chain.
import Foundation

public enum OLECompoundError: Error, Equatable {
    case notOLE
    case malformed(String)
}

public enum OLECompound {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    /// Upper bound on sectors followed in any chain (directory, DIFAT); also stops cycles.
    static let maxChainLength = 4096
    /// The fallback scan looks at this many leading bytes.
    static let scanLimit = 4 * 1024 * 1024

    /// Names of all used directory entries (root, storages, streams) in directory order.
    public static func streamNames(url: URL) throws -> [String] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw OLECompoundError.malformed("cannot read file: \(error.localizedDescription)") }
        return try streamNames(data: data)
    }

    /// True when the file is an OLE container holding an encrypted OOXML package. If the directory
    /// cannot be parsed, falls back to searching the first 4 MB for the UTF-16LE name "EncryptionInfo".
    public static func isEncryptedOOXML(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return isEncryptedOOXML(data: data)
    }

    static func isEncryptedOOXML(data: Data) -> Bool {
        do {
            let names = try streamNames(data: data)
            return names.contains { n in
                n.caseInsensitiveCompare("EncryptionInfo") == .orderedSame
                    || n.caseInsensitiveCompare("EncryptedPackage") == .orderedSame
            }
        } catch OLECompoundError.notOLE {
            return false
        } catch {
            let needle = Data("EncryptionInfo".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            return data.prefix(scanLimit).range(of: needle) != nil
        }
    }

    static func streamNames(data: Data) throws(OLECompoundError) -> [String] {
        let r = Bytes(data)
        guard r.count >= 8, (0..<8).allSatisfy({ r.u8($0) == signature[$0] }) else { throw .notOLE }
        guard r.count >= 512, let shift = r.u16(0x1E) else { throw .malformed("header truncated") }
        guard shift == 9 || shift == 12 else { throw .malformed("sector shift \(shift)") }
        let ss = 1 << Int(shift)
        let sectorCount = (r.count - ss + ss - 1) / ss
        func offset(_ sector: UInt32) -> Int? {
            let s = Int(sector)
            guard s < sectorCount else { return nil }
            return (s + 1) * ss
        }

        // FAT sector list: 109 DIFAT entries in the header, then the DIFAT sector chain.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            guard let v = r.u32(0x4C + 4 * i), Int(v) < sectorCount else { break }
            fatSectors.append(v)
        }
        if var difat = r.u32(0x44) {
            let perSector = ss / 4 - 1
            var seen = Set<UInt32>()
            while seen.count < maxChainLength, let base = offset(difat), seen.insert(difat).inserted {
                for i in 0..<perSector {
                    if let v = r.u32(base + 4 * i), Int(v) < sectorCount { fatSectors.append(v) }
                }
                guard let next = r.u32(base + 4 * perSector) else { break }
                difat = next
            }
        }
        func next(_ sector: UInt32) -> UInt32? {
            let perSector = ss / 4
            let idx = Int(sector) / perSector
            guard idx < fatSectors.count, let base = offset(fatSectors[idx]) else { return nil }
            return r.u32(base + 4 * (Int(sector) % perSector))
        }

        guard let first = r.u32(0x30), offset(first) != nil else { throw .malformed("directory sector out of range") }
        var names: [String] = []
        var sector = first
        var seen = Set<UInt32>()
        while seen.count < maxChainLength, let base = offset(sector), seen.insert(sector).inserted {
            for e in stride(from: base, to: base + ss, by: 128) {
                guard let len = r.u16(e + 0x40), let type = r.u8(e + 0x42) else { break }
                guard type == 1 || type == 2 || type == 5, len >= 2, len <= 64, len % 2 == 0 else { continue }
                var units: [UInt16] = []
                for i in 0..<(Int(len) / 2 - 1) {
                    guard let u = r.u16(e + 2 * i) else { break }
                    units.append(u)
                }
                names.append(String(decoding: units, as: UTF16.self))
            }
            guard let n = next(sector) else { break }
            sector = n
        }
        return names
    }

    /// Bounds-checked little-endian reader.
    private struct Bytes {
        let data: Data
        let count: Int
        init(_ data: Data) { self.data = data; self.count = data.count }
        func u8(_ i: Int) -> UInt8? {
            guard i >= 0, i < count else { return nil }
            return data[data.startIndex + i]
        }
        func u16(_ i: Int) -> UInt16? {
            guard let a = u8(i), let b = u8(i + 1) else { return nil }
            return UInt16(a) | UInt16(b) << 8
        }
        func u32(_ i: Int) -> UInt32? {
            guard let a = u16(i), let b = u16(i + 2) else { return nil }
            return UInt32(a) | UInt32(b) << 16
        }
    }
}
