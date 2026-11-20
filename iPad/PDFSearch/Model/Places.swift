import Foundation
import IndexKit

/// A place the user shared with the app (a folder picked in the document picker), stored as a
/// security-scoped bookmark. The app's own Documents folder is a built-in place without bookmark.
struct SharedPlace: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// nil for the built-in place (the app's own folder in the Files app).
    var bookmark: Data?

    static let builtInID = UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!
}

/// A place resolved for this run: URL with access started and its index.
final class PlaceRuntime: Identifiable, @unchecked Sendable {
    let place: SharedPlace
    let url: URL
    let store: IndexStore?
    let openError: String?
    private let scoped: Bool

    var id: UUID { place.id }

    init(place: SharedPlace, url: URL, scoped: Bool) {
        self.place = place
        self.url = url
        self.scoped = scoped
        do {
            let location = IndexStore.location(forFolder: url)
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            store = try IndexStore(fileURL: location, root: url)
            openError = nil
        } catch {
            store = nil
            openError = String(describing: error)
        }
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

/// Keys of the view settings kept between launches (the app's own defaults, not shared with the Mac app).
enum SettingsKey {
    static let showFolderTree = "showFolderTree"
    static let previewOnLeft = "previewOnLeft"
    static let tileSize = "tileSize"
    static let tileSizeRange: ClosedRange<Double> = 40...120
}

/// Persists the shared places (bookmarks) in the app's own defaults.
enum PlaceStorage {
    private static let key = "sharedPlaces.v1"

    static func load(from defaults: UserDefaults = .standard) -> [SharedPlace] {
        guard let data = defaults.data(forKey: key),
              let places = try? JSONDecoder().decode([SharedPlace].self, from: data) else { return [] }
        return places
    }

    static func save(_ places: [SharedPlace], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(places.filter { $0.bookmark != nil }) {
            defaults.set(data, forKey: key)
        }
    }

    static var documentsFolder: URL { URL.documentsDirectory }

    /// Makes a place from a URL the document picker returned (security scoped).
    static func makePlace(from url: URL) throws -> SharedPlace {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return SharedPlace(id: UUID(), name: displayName(for: url), bookmark: data)
    }

    static func displayName(for url: URL) -> String {
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    /// Resolves a place; refreshes a stale bookmark. Returns nil when it cannot be resolved.
    static func resolve(_ place: SharedPlace) -> (runtime: PlaceRuntime?, refreshed: SharedPlace?, error: String?) {
        guard let bookmark = place.bookmark else {
            return (PlaceRuntime(place: place, url: documentsFolder, scoped: false), nil, nil)
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = url.startAccessingSecurityScopedResource()
            var refreshed: SharedPlace?
            if stale, let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshed = place
                refreshed?.bookmark = data
            }
            return (PlaceRuntime(place: place, url: url, scoped: started), refreshed, nil)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }
}
