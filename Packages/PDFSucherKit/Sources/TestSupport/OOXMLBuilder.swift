// OOXMLBuilder.swift — Task 1 (OOXMLKit)
// Writes small, valid zip containers (the OPC package format of .pptx/.docx) for tests.
import Compression
import Foundation

/// Builds zip files: local headers, central directory, EOCD, correct CRC-32, UTF-8 flag (bit 11)
/// for non-ASCII names, entries stored or raw-deflated. Test-only helper.
public struct OOXMLBuilder {
    struct Entry {
        var path: String
        var data: Data
        var deflate: Bool
    }

    var entries: [Entry] = []

    public init() {}

    /// Adds a UTF-8 text entry.
    public mutating func add(_ path: String, _ xml: String, deflate: Bool = true) {
        entries.append(Entry(path: path, data: Data(xml.utf8), deflate: deflate))
    }

    /// Adds a binary entry.
    public mutating func addData(_ path: String, _ data: Data, deflate: Bool = false) {
        entries.append(Entry(path: path, data: data, deflate: deflate))
    }

    /// Zip file comment (written into the EOCD).
    public var comment = Data()

    public func write(to url: URL, zip64: Bool = false, dataDescriptors: Bool = false) throws {
        try build(zip64: zip64, dataDescriptors: dataDescriptors).write(to: url)
    }

    /// - Parameters:
    ///   - zip64: write sizes/offsets into a zip64 extra field and add zip64 EOCD record + locator.
    ///   - dataDescriptors: set flag bit 3; local headers carry zeros, the data is followed by a descriptor.
    public func build(zip64: Bool = false, dataDescriptors: Bool = false) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let nameBytes = Array(e.path.utf8)
            let isASCII = nameBytes.allSatisfy { $0 < 0x80 }
            var flags: UInt16 = isASCII ? 0 : 0x0800
            if dataDescriptors { flags |= 0x0008 }
            let crc = Self.crc32(e.data)
            let payload: Data
            let method: UInt16
            if e.deflate, let d = Self.rawDeflate(e.data) {
                payload = d
                method = 8
            } else {
                payload = e.data
                method = 0
            }
            let offset = UInt64(out.count)
            // local header
            out.le32(0x04034b50); out.le16(20); out.le16(flags); out.le16(method)
            out.le16(0); out.le16(0x21)
            if dataDescriptors {
                out.le32(0); out.le32(0); out.le32(0)
            } else {
                out.le32(crc); out.le32(UInt32(payload.count)); out.le32(UInt32(e.data.count))
            }
            out.le16(UInt16(nameBytes.count)); out.le16(0)
            out.append(contentsOf: nameBytes)
            out.append(payload)
            if dataDescriptors {
                out.le32(0x08074b50); out.le32(crc)
                out.le32(UInt32(payload.count)); out.le32(UInt32(e.data.count))
            }
            // central header
            central.le32(0x02014b50); central.le16(20); central.le16(zip64 ? 45 : 20)
            central.le16(flags); central.le16(method); central.le16(0); central.le16(0x21)
            central.le32(crc)
            if zip64 {
                central.le32(0xFFFF_FFFF); central.le32(0xFFFF_FFFF)
            } else {
                central.le32(UInt32(payload.count)); central.le32(UInt32(e.data.count))
            }
            central.le16(UInt16(nameBytes.count)); central.le16(zip64 ? 28 : 0)
            central.le16(0); central.le16(0); central.le16(0); central.le32(0)
            central.le32(zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(contentsOf: nameBytes)
            if zip64 {
                central.le16(0x0001); central.le16(24)
                central.le64(UInt64(e.data.count)); central.le64(UInt64(payload.count)); central.le64(offset)
            }
        }
        let cdOffset = UInt64(out.count)
        out.append(central)
        if zip64 {
            let z64Offset = UInt64(out.count)
            out.le32(0x06064b50); out.le64(44); out.le16(45); out.le16(45)
            out.le32(0); out.le32(0)
            out.le64(UInt64(entries.count)); out.le64(UInt64(entries.count))
            out.le64(UInt64(central.count)); out.le64(cdOffset)
            out.le32(0x07064b50); out.le32(0); out.le64(z64Offset); out.le32(1)
            out.le32(0x06054b50); out.le16(0); out.le16(0); out.le16(0xFFFF); out.le16(0xFFFF)
            out.le32(0xFFFF_FFFF); out.le32(0xFFFF_FFFF); out.le16(UInt16(comment.count))
        } else {
            out.le32(0x06054b50); out.le16(0); out.le16(0)
            out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
            out.le32(UInt32(central.count)); out.le32(UInt32(cdOffset)); out.le16(UInt16(comment.count))
        }
        out.append(comment)
        return out
    }

    /// First bytes of an OLE compound file (legacy .ppt/.doc, encrypted OOXML), padded to one sector.
    public static func oleCompoundFile() -> Data {
        var d = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        d.append(Data(count: 504))
        return d
    }

    // MARK: - helpers

    static func rawDeflate(_ data: Data) -> Data? {
        if data.isEmpty { return nil }
        let cap = data.count + data.count / 16 + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = data.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(dst[0..<n]) : nil
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        crcTable.withUnsafeBufferPointer { t in
            data.withUnsafeBytes { raw in
                for b in raw { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func le64(_ v: UInt64) { for i in 0..<8 { append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
}
