// CFBBuilder.swift — Task 8 (SlideKit)
// Writes minimal OLE compound files (CFB v3) for tests: encrypted OOXML vs legacy binary Office files.
import Foundation

public enum CFBBuilder {
    public static let endOfChain: UInt32 = 0xFFFF_FFFE
    public static let freeSect: UInt32 = 0xFFFF_FFFF
    public static let fatSect: UInt32 = 0xFFFF_FFFD

    /// 512-byte sectors. Sector 0 is the only FAT sector; the directory ("Root Entry" + one stream entry
    /// per name, 4 entries per sector) starts at sector 1 and is chained through the FAT.
    /// - Parameter directoryChain: overrides the FAT entries of the directory sectors (corrupt chains).
    /// - Parameter firstDirectorySector: overrides the header field (corrupt headers).
    public static func file(streams: [String], directoryChain: [UInt32]? = nil,
                            firstDirectorySector: UInt32 = 1) -> Data {
        let names = ["Root Entry"] + streams
        let dirSectors = (names.count + 3) / 4

        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.append(Data(count: 16))                  // CLSID
        header.le16(0x3E); header.le16(3)               // minor, major version
        header.le16(0xFFFE); header.le16(9); header.le16(6)  // byte order, sector shift, mini shift
        header.append(Data(count: 6))
        header.le32(0)                                  // directory sectors (0 in v3)
        header.le32(1)                                  // FAT sectors
        header.le32(firstDirectorySector)
        header.le32(0)                                  // transaction signature
        header.le32(4096)                               // mini stream cutoff
        header.le32(endOfChain); header.le32(0)         // mini FAT
        header.le32(endOfChain); header.le32(0)         // DIFAT
        header.le32(0)                                  // DIFAT[0] = FAT sector 0
        for _ in 1..<109 { header.le32(freeSect) }

        var fat = Data()
        fat.le32(fatSect)
        let chain = directoryChain ?? (1...dirSectors).map { $0 == dirSectors ? endOfChain : UInt32($0 + 1) }
        for v in chain { fat.le32(v) }
        while fat.count < 512 { fat.le32(freeSect) }

        var dir = Data()
        for (i, name) in names.enumerated() {
            var e = Data()
            let units = Array(name.utf16.prefix(31))
            for u in units { e.le16(u) }
            e.append(Data(count: 64 - e.count))
            e.le16(UInt16((units.count + 1) * 2))
            e.append(i == 0 ? 5 : 2)                    // root storage / stream
            e.append(1)                                 // black
            e.le32(freeSect); e.le32(freeSect)          // left/right sibling
            e.le32(i == 0 && names.count > 1 ? 1 : freeSect)  // child
            e.append(Data(count: 16 + 4 + 16))          // CLSID, state bits, times
            e.le32(endOfChain); e.le32(0); e.le32(0)    // start sector, size
            dir.append(e)
        }
        while dir.count < dirSectors * 512 { dir.append(Data(count: 128)) }
        return header + fat + dir
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}
