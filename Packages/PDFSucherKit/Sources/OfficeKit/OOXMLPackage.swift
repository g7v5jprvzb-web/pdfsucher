// OOXMLPackage.swift — 1.3 Office: the small ZIP and XML readers shared by `PresentationSlides` (Task 6) and
// `WordPageSetup` (Task 7). Moved out of PresentationSlides.swift unchanged.
import Compression
import Foundation

/// Streams the start tags of an XML document (local names, namespace prefixes stripped).
final class XMLScan: NSObject, XMLParserDelegate {
    /// Return false to stop.
    private let visit: (String, [String: String]) -> Bool
    private init(visit: @escaping (String, [String: String]) -> Bool) { self.visit = visit }

    static func elements(in data: Data, visit: @escaping (_ localName: String, _ attributes: [String: String]) -> Bool) {
        let parser = XMLParser(data: data)
        let scan = XMLScan(visit: visit)
        parser.delegate = scan
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    /// The `r:id` attribute (officeDocument relationships namespace), whatever its prefix.
    static func relationshipID(_ attributes: [String: String]) -> String? {
        attributes.first { $0.key.hasSuffix(":id") }?.value
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if !visit(local, attributeDict) { parser.abortParsing() }
    }
}

/// Reads single entries of a ZIP file (stored or deflated) via its central directory. No ZIP64 (rejected as
/// `Failure`), no encryption; enough for the small XML parts of an Office package. Entries larger than
/// `maxEntrySize` uncompressed are not inflated (`data(at:)` → nil).
struct ZipArchive {
    struct Failure: Error {}

    static let maxEntrySize = 64 * 1024 * 1024

    private struct Entry { let method: UInt16; let compressedSize: Int; let size: Int; let localHeaderOffset: Int }

    private let data: Data
    private let entries: [String: Entry]

    init(url: URL) throws {
        // `.mappedIfSafe`, not `.alwaysMapped`: Foundation maps only files on local volumes; a mapped file on a
        // network share or USB stick that is truncated or unmounted while we read would end in SIGBUS.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = data
        // End of central directory: 22 bytes + comment (≤ 65535), searched backwards.
        let minimum = 22
        guard data.count >= minimum else { throw Failure() }
        var eocd = -1
        var position = data.count - minimum
        let lowest = max(0, data.count - minimum - 65_535)
        while position >= lowest {
            if Self.uint32(data, position) == 0x0605_4B50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw Failure() }
        let rawCount = Self.uint16(data, eocd + 10)
        let rawOffset = Self.uint32(data, eocd + 16)
        guard rawCount != 0xFFFF, rawOffset != 0xFFFF_FFFF else { throw Failure() } // ZIP64
        let count = Int(rawCount)
        var offset = Int(rawOffset)
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, Self.uint32(data, offset) == 0x0201_4B50 else { throw Failure() }
            let nameLength = Int(Self.uint16(data, offset + 28))
            let extraLength = Int(Self.uint16(data, offset + 30))
            let commentLength = Int(Self.uint16(data, offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw Failure() }
            let nameStart = data.startIndex + offset + 46
            let name = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)
            let compressedSize = Self.uint32(data, offset + 20), size = Self.uint32(data, offset + 24)
            let localHeaderOffset = Self.uint32(data, offset + 42)
            guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localHeaderOffset != 0xFFFF_FFFF else {
                throw Failure() // ZIP64
            }
            entries[name] = Entry(method: Self.uint16(data, offset + 10), compressedSize: Int(compressedSize),
                                  size: Int(size), localHeaderOffset: Int(localHeaderOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The uncompressed entry, or nil when missing, damaged or in an unsupported format.
    func data(at path: String) -> Data? {
        guard let entry = entries[path], entry.size <= Self.maxEntrySize,
              entry.compressedSize <= data.count else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, Self.uint32(data, header) == 0x0403_4B50 else { return nil }
        let start = header + 30 + Int(Self.uint16(data, header + 26)) + Int(Self.uint16(data, header + 28))
        guard start + entry.compressedSize <= data.count else { return nil }
        let compressed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return entry.size == entry.compressedSize ? Data(compressed) : nil
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), as stored in ZIP files.
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            return written == entry.size ? output : nil
        default:
            return nil
        }
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
