import Foundation
import IndexKit

/// iCloud Drive keeps files that are not on the iPad as hidden placeholders (`.Name.pdf.icloud`).
/// The folder scanner skips hidden files, so before indexing these are downloaded.
enum ICloudPlaceholders {
    /// The real file URLs behind placeholders of PDF/JPEG files below `root` (and files iCloud reports
    /// as not downloaded).
    static func pending(below root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                if accepted(realName) { result.append(url.deletingLastPathComponent().appendingPathComponent(realName)) }
                continue
            }
            guard accepted(name),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isUbiquitousItem == true,
                  let status = values.ubiquitousItemDownloadingStatus,
                  status == .notDownloaded else { continue }
            result.append(url)
        }
        return result
    }

    private static func accepted(_ name: String) -> Bool {
        SupportedSourceTypes.accepts(fileName: name, includeImages: true, includeOffice: false)
    }

    private static func isLocal(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    /// Starts the downloads and waits until they are local (or `timeout` passes).
    /// Returns the files still missing.
    static func download(_ urls: [URL], timeout: Duration = .seconds(180),
                         progress: @Sendable (Int, Int) -> Void) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        for url in urls { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var missing = urls
        while !missing.isEmpty, clock.now < deadline, !Task.isCancelled {
            missing = missing.filter { !isLocal($0) }
            progress(urls.count - missing.count, urls.count)
            if missing.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return missing
    }
}
