// ZipArchive.swift — Task 1 (OOXMLKit)
// Read-only, lazy zip reader (stored + raw deflate, zip64). The file is memory-mapped; opening parses
// only the central directory, `data(_:)` touches only the bytes of the requested entry.
import Compression
import Foundation

public enum ZipError: Error, Equatable {
    case notAZip
    case oleCompound
    case truncated
    case unsupportedMethod(UInt16)
    case entryMissing(String)
    case corrupt(String)
}

public struct ZipArchive: Sendable {
    /// Largest uncompressed entry we are willing to inflate (sizes come from an untrusted directory).
    static let maxEntrySize: UInt64 = 512 * 1024 * 1024

    private struct Entry: Sendable {
        var method: UInt16
        var flags: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localOffset: UInt64
    }

    private let bytes: Data
    /// Keyed by UTF-8 bytes: Swift's String equality is canonical equivalence (NFC == NFD), which we do not want.
    private let table: [[UInt8]: Entry]
    /// Entry names in central-directory order (duplicates removed, first wins).
    public let entryNames: [String]

    public init(url: URL) throws(ZipError) {
        let mapped: Data
        do {
            mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ZipError.corrupt("cannot read file: \(error.localizedDescription)")
        }
        try self.init(data: mapped)
    }

    /// The archive in `mapped` (read by the caller, e.g. to let its I/O errors through unchanged).
    public init(data mapped: Data) throws(ZipError) {
        let r = Reader(mapped)
        if r.count >= 8, r.byte(0) == 0xD0, r.byte(1) == 0xCF, r.byte(2) == 0x11, r.byte(3) == 0xE0,
           r.byte(4) == 0xA1, r.byte(5) == 0xB1, r.byte(6) == 0x1A, r.byte(7) == 0xE1 {
            throw ZipError.oleCompound
        }
        guard r.count >= 4, r.byte(0) == 0x50, r.byte(1) == 0x4B else { throw ZipError.notAZip }
        guard let eocd = Self.findEOCD(r) else { throw ZipError.truncated }

        var total = UInt64(r.u16(eocd + 10) ?? 0)
        var cdSize = UInt64(r.u32(eocd + 12) ?? 0)
        var cdOffset = UInt64(r.u32(eocd + 16) ?? 0)
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocd >= 20, r.u32(eocd - 20) == 0x0706_4b50, let z64 = r.u64(eocd - 12) else {
                throw ZipError.corrupt("zip64 locator missing")
            }
            guard z64 <= UInt64(r.count), r.u32(Int(z64)) == 0x0606_4b50,
                  let t = r.u64(Int(z64) + 32), let s = r.u64(Int(z64) + 40), let o = r.u64(Int(z64) + 48)
            else { throw ZipError.corrupt("zip64 end of central directory invalid") }
            total = t; cdSize = s; cdOffset = o
        }
        guard cdOffset <= UInt64(r.count), cdSize <= UInt64(r.count) - cdOffset else { throw ZipError.truncated }

        var table: [[UInt8]: Entry] = [:]
        var names: [String] = []
        var p = Int(cdOffset)
        let end = Int(cdOffset + cdSize)
        var n: UInt64 = 0
        while n < total {
            guard p + 46 <= end else { throw ZipError.truncated }
            guard r.u32(p) == 0x0201_4b50 else { throw ZipError.corrupt("bad central directory header") }
            let flags = r.u16(p + 8) ?? 0
            let method = r.u16(p + 10) ?? 0
            var csize = UInt64(r.u32(p + 20) ?? 0)
            var usize = UInt64(r.u32(p + 24) ?? 0)
            let nameLen = Int(r.u16(p + 28) ?? 0)
            let extraLen = Int(r.u16(p + 30) ?? 0)
            let commentLen = Int(r.u16(p + 32) ?? 0)
            var offset = UInt64(r.u32(p + 42) ?? 0)
            let nameStart = p + 46
            let extraStart = nameStart + nameLen
            let next = extraStart + extraLen + commentLen
            guard next <= end else { throw ZipError.truncated }
            // zip64 extended information: only fields whose 32-bit value is saturated are present
            var q = extraStart
            let extraEnd = extraStart + extraLen
            while q + 4 <= extraEnd {
                let tag = r.u16(q) ?? 0
                let len = Int(r.u16(q + 2) ?? 0)
                let body = q + 4
                guard body + len <= extraEnd else { break }
                if tag == 0x0001 {
                    var f = body
                    func take() -> UInt64? {
                        guard f + 8 <= body + len, let v = r.u64(f) else { return nil }
                        f += 8
                        return v
                    }
                    if usize == 0xFFFF_FFFF { usize = take() ?? usize }
                    if csize == 0xFFFF_FFFF { csize = take() ?? csize }
                    if offset == 0xFFFF_FFFF { offset = take() ?? offset }
                }
                q = body + len
            }
            let name = Self.decodeName(r.slice(nameStart, nameLen), utf8Flag: flags & 0x0800 != 0)
            let key = Array(name.utf8)
            if table[key] == nil {
                table[key] = Entry(method: method, flags: flags, compressedSize: csize,
                                    uncompressedSize: usize, localOffset: offset)
                names.append(name)
            }
            p = next
            n += 1
        }
        self.bytes = mapped
        self.table = table
        self.entryNames = names
    }

    public func contains(_ name: String) -> Bool { table[Array(name.utf8)] != nil }

    public func data(_ name: String) throws(ZipError) -> Data {
        try data(name, maxSize: Self.maxEntrySize)
    }

    /// As `data(_:)`, with a lower limit for the uncompressed size (callers that read only small parts).
    public func data(_ name: String, maxSize: UInt64) throws(ZipError) -> Data {
        guard let e = table[Array(name.utf8)] else { throw ZipError.entryMissing(name) }
        if e.flags & 0x0001 != 0 { throw ZipError.corrupt("encrypted entry \(name)") }
        guard e.method == 0 || e.method == 8 else { throw ZipError.unsupportedMethod(e.method) }
        let r = Reader(bytes)
        let total = UInt64(r.count)
        guard e.localOffset <= total, total - e.localOffset >= 30 else { throw ZipError.truncated }
        let lo = Int(e.localOffset)
        guard r.u32(lo) == 0x0403_4b50 else { throw ZipError.corrupt("bad local header for \(name)") }
        let nameLen = UInt64(r.u16(lo + 26) ?? 0)
        let extraLen = UInt64(r.u16(lo + 28) ?? 0)
        let start = e.localOffset + 30 + nameLen + extraLen
        guard start <= total, e.compressedSize <= total - start else { throw ZipError.truncated }
        guard e.uncompressedSize <= min(maxSize, Self.maxEntrySize) else { throw ZipError.corrupt("entry \(name) too large") }
        let payloadStart = Int(start)
        let payloadCount = Int(e.compressedSize)
        if e.method == 0 {
            guard e.compressedSize == e.uncompressedSize else { throw ZipError.corrupt("stored size mismatch") }
            return r.slice(payloadStart, payloadCount)  // copy out of the mapping
        }
        // Deflate cannot expand more than ~1032:1; reject claimed sizes beyond that.
        guard e.uncompressedSize <= e.compressedSize &* 1100 &+ 1024 else {
            throw ZipError.corrupt("implausible size for \(name)")
        }
        let outSize = Int(e.uncompressedSize)
        if outSize == 0 { return Data() }
        if payloadCount == 0 { throw ZipError.corrupt("empty deflate stream for \(name)") }
        var written = 0
        // One byte of room beyond the declared size: a stream that is longer than its directory entry claims fills it
        // and is rejected, instead of being cut off silently at `outSize` (audit 2026-11-15).
        let out = [UInt8](unsafeUninitializedCapacity: outSize + 1) { buf, count in
            // decode straight from the mapped bytes, no intermediate copy
            written = bytes.withUnsafeBytes { src -> Int in
                guard let sp = src.bindMemory(to: UInt8.self).baseAddress, let dp = buf.baseAddress,
                      payloadStart + payloadCount <= src.count else { return 0 }
                return compression_decode_buffer(dp, outSize + 1, sp + payloadStart, payloadCount, nil, COMPRESSION_ZLIB)
            }
            count = written
        }
        guard written == outSize else { throw ZipError.corrupt("inflate failed for \(name)") }
        return Data(out)
    }

    // MARK: - internals

    private static func findEOCD(_ r: Reader) -> Int? {
        guard r.count >= 22 else { return nil }
        let lowest = max(0, r.count - 22 - 65535)
        var i = r.count - 22
        var fallback: Int?
        while i >= lowest {
            if r.byte(i) == 0x50, r.u32(i) == 0x0605_4b50 {
                // a real EOCD's comment runs exactly to the end of the file; a fake one inside a comment does not
                if Int(r.u16(i + 20) ?? 0xFFFF) == r.count - i - 22 { return i }
                if fallback == nil { fallback = i }
            }
            i -= 1
        }
        return fallback
    }

    /// Names with flag bit 11 are UTF-8. Without it: UTF-8 if valid (many writers omit the flag),
    /// otherwise ISO-8859-1. Never normalised.
    private static func decodeName(_ raw: Data, utf8Flag: Bool) -> String {
        if let s = String(validating: raw, as: UTF8.self) { return s }
        if utf8Flag { return String(decoding: raw, as: UTF8.self) }
        return String(raw.map { Character(Unicode.Scalar($0)) })
    }
}

/// Bounds-checked little-endian reads over a Data (no traps on any input).
private struct Reader {
    let data: Data
    let count: Int
    init(_ d: Data) { data = d; count = d.count }

    func byte(_ i: Int) -> UInt8? {
        guard i >= 0, i < count else { return nil }
        return data[data.startIndex + i]
    }
    func u16(_ i: Int) -> UInt16? {
        guard i >= 0, i <= count - 2 else { return nil }
        let b = data.startIndex + i
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }
    func u32(_ i: Int) -> UInt32? {
        guard i >= 0, i <= count - 4 else { return nil }
        let b = data.startIndex + i
        return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
    }
    func u64(_ i: Int) -> UInt64? {
        guard let lo = u32(i), let hi = u32(i + 4) else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }
    func slice(_ i: Int, _ n: Int) -> Data {
        guard i >= 0, n >= 0, i <= count, n <= count - i else { return Data() }
        return data.subdata(in: (data.startIndex + i)..<(data.startIndex + i + n))
    }
}
