import Foundation

/// Security-scoped access to folders picked in the Files app.
///
/// iOS only lets the app read a folder outside its sandbox while it holds the access the user
/// granted in the picker. The bookmark keeps that grant across launches; the app starts access
/// once per launch and keeps it while the folder is in the library.
enum FolderAccess {
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark and starts access. Returns a fresh bookmark when the stored one is stale.
    static func resolve(_ bookmark: Data) throws -> (url: URL, refreshedBookmark: Data?) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        // Returns false for places that need no grant (inside the app container); access works anyway.
        _ = url.startAccessingSecurityScopedResource()
        let refreshed = isStale ? try? Self.bookmark(for: url) : nil
        return (url, refreshed)
    }
}
