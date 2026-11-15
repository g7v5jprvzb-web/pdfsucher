// FolderSidebar.swift — Ordnerleiste: sections „Quellen“ and „Orte“, filter header over the grid
import AppKit
import SwiftUI

/// List selection ids ↔ folder filter (pure).
enum FolderSidebarSelection {
    static let allID = "pdfsucher.allSources"
    static let singleFilesID = "pdfsucher.singleFiles"
    private static let placePrefix = "place:"

    static func placeID(_ url: URL) -> String { placePrefix + url.standardizedFileURL.path }

    static func place(in selection: Set<String>) -> URL? {
        selection.first { $0.hasPrefix(placePrefix) }.map { URL(fileURLWithPath: String($0.dropFirst(placePrefix.count)), isDirectory: true) }
    }

    /// The filter for a selection of folder ids (⌘-click: several); „Alle Quellen“ or nothing = no filter.
    static func filter(for selection: Set<String>, singleFiles: [URL]) -> FolderFilter {
        var filter = FolderFilter()
        guard !selection.contains(allID) else { return filter }
        for id in selection.sorted() where !id.hasPrefix(placePrefix) {
            if id == singleFilesID {
                filter.selectSingleFiles(singleFiles, adding: true)
            } else {
                filter.select(URL(fileURLWithPath: id, isDirectory: true), adding: true)
            }
        }
        return filter
    }

    /// The list's raw change (click, ⌘-click, arrows) made consistent: „Alle Quellen“ and folders exclude each
    /// other, nothing chosen means „Alle Quellen“ (review I5).
    static func normalize(old: Set<String>, new: Set<String>) -> Set<String> {
        if new.isEmpty { return [allID] }
        if new.contains(allID), !old.contains(allID) { return [allID] }
        if new.contains(allID), new.count > 1 { return new.subtracting([allID]) }
        return new
    }

    /// The folders to open the tree to after a filter change: the newly chosen ones, unless the list itself
    /// made the change (`applied`); nil for nothing (a folder removed, single files re-synced).
    static func toReveal(old: FolderFilter, new: FolderFilter, applied: FolderFilter?) -> FolderFilter? {
        guard new != applied else { return nil }
        let before = Set(old.folders)
        var added = FolderFilter()
        for folder in new.folders where !before.contains(folder) { added.select(folder, adding: true) }
        return added.folders.isEmpty ? nil : added
    }

    static func ids(for filter: FolderFilter) -> Set<String> {
        if filter.isEmpty { return [allID] }
        var ids = Set(filter.folders.map(\.path))
        if !filter.singleFiles.isEmpty { ids.insert(singleFilesID) }
        return ids
    }
}

/// The folder bar at the window's left edge.
struct FolderSidebar: View {
    let model: any ViewerModel
    @State private var selection: Set<String> = [FolderSidebarSelection.allID]
    /// Read once and on mount/unmount, not on every redraw (review).
    @State private var places = Places.standard()
    /// Chosen folders not in the tree yet (a place still loading): opened when they appear.
    @State private var pendingReveal: FolderFilter?
    /// The filter the list itself just set (click, ⌘-click, arrows): no opening and no scrolling for it.
    @State private var lastApplied: FolderFilter?

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.folderFilter) { old, filter in
                    // ✕ in the header, a place loaded, a source removed: the list follows.
                    let ids = FolderSidebarSelection.ids(for: filter)
                    if ids != selection { selection = ids }
                    let applied = lastApplied
                    lastApplied = nil
                    if filter.folders.isEmpty { pendingReveal = nil }
                    if let added = FolderSidebarSelection.toReveal(old: old, new: filter, applied: applied) { reveal(added, proxy) }
                }
                .onChange(of: model.folderTree) { _, _ in
                    if let pending = pendingReveal { reveal(pending, proxy) }
                }
                // Shown again (⌃⌘S) with a filter on: the list shows it (review I6), opened down to it.
                .onAppear {
                    selection = FolderSidebarSelection.ids(for: model.folderFilter)
                    reveal(model.folderFilter, proxy)
                }
        }
    }

    /// Opens the tree down to folders chosen by code, a place or a restored filter, and scrolls the first one
    /// into view; ones not in the tree yet are tried again with the next tree.
    private func reveal(_ filter: FolderFilter, _ proxy: ScrollViewProxy) {
        pendingReveal = nil
        guard !filter.folders.isEmpty else { return }
        let result = model.folderBar.reveal(filter, in: model.folderTree)
        if !result.allFound { pendingReveal = filter }
        guard let shown = result.first else { return }
        // Two turns later: the opened rows must be in the outline view before it can scroll to them.
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(shown)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section(ViewerText.folderSourcesSection) {
                Label(ViewerText.allSources, systemImage: "tray.full")
                    .tag(FolderSidebarSelection.allID)
                    .accessibilityIdentifier("folderAll")
                FolderNodeRows(nodes: model.folderTree, model: model)
            }
            Section(ViewerText.folderPlacesSection) {
                // Places are not part of the selection: arrows never add a source; a click does (review I3/I4).
                ForEach(places, id: \.url) { place in
                    PlaceRow(url: place.url, name: place.name, symbol: Self.symbol(place)) { url in
                        Task { await model.openPlace(url) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("folderTree")
        .onChange(of: selection) { old, new in
            let normalized = FolderSidebarSelection.normalize(old: old, new: new)
            if normalized != new { selection = normalized; return }
            apply(new)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in places = Places.standard() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in places = Places.standard() }
    }

    private func apply(_ selection: Set<String>) {
        let filter = FolderSidebarSelection.filter(for: selection, singleFiles: model.sources.filter { !$0.isFolder }.map(\.url))
        guard filter != model.folderFilter else { return }
        lastApplied = filter
        model.setFolderFilter(filter)
    }

    static func symbol(_ place: Place) -> String {
        switch place.name {
        case "Home": "house"
        case "Schreibtisch": "menubar.dock.rectangle"
        case "Dokumente": "doc"
        case "Downloads": "arrow.down.circle"
        default: "externaldrive"
        }
    }
}

extension FolderNode {
    /// The list selection id (and scroll id) of the row.
    var selectionID: String { kind == .singleFiles ? FolderSidebarSelection.singleFilesID : url.standardizedFileURL.path }
}

/// Folders of „Quellen“ with their subfolders. Which ones are open is kept in `FolderBarSettings` (also for
/// the next start), so the tree can be opened down to a chosen folder; collapsed content is not built.
private struct FolderNodeRows: View {
    let nodes: [FolderNode]
    let model: any ViewerModel

    // The ForEach identity (`FolderNode.id`, the path) is the scroll id of `reveal`.
    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                FolderRow(node: node, model: model)
                    .tag(node.selectionID)
            } else {
                DisclosureGroup(isExpanded: expanded(node)) {
                    FolderNodeRows(nodes: node.children, model: model)
                } label: {
                    FolderRow(node: node, model: model)
                }
                .tag(node.selectionID)
            }
        }
    }

    private func expanded(_ node: FolderNode) -> Binding<Bool> {
        let bar = model.folderBar
        return Binding(get: { bar.isExpanded(node) }, set: { bar.setExpanded(node.url, $0, byDefault: node.isSourceRoot) })
    }
}

/// One folder of „Quellen“ with its file count; context menu.
private struct FolderRow: View {
    let node: FolderNode
    let model: any ViewerModel

    var body: some View {
        HStack(spacing: 6) {
            // No file of the chosen kinds („Dateitypen“): the folder stays, dimmed.
            Label(node.name, systemImage: node.kind == .singleFiles ? "doc.on.doc" : node.isSourceRoot ? "folder.fill" : "folder")
                .lineLimit(1)
                .foregroundStyle(node.fileCount == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer(minLength: 4)
            Text(node.fileCount.formatted(.number.locale(Locale(identifier: "de_DE"))))
                .foregroundStyle(node.fileCount == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("folderRow")
        .contextMenu {
            if node.kind == .folder {
                Button(ViewerText.revealInFinder) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            }
            if node.isSourceRoot {
                Button(ViewerText.removeAsSource) { model.removeSource(node.url) }
                Button(ViewerText.rebuildIndex) { model.requestDeleteIndex(for: node.url) }
            }
        }
    }
}

/// A folder of „Orte“: children are listed in the background when it is opened (folders only).
private struct PlaceRow: View {
    let url: URL
    let name: String
    let symbol: String
    let open: (URL) -> Void
    @State private var expanded = false
    @State private var children: [URL]?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let children {
                ForEach(children, id: \.self) { child in
                    PlaceRow(url: child, name: child.lastPathComponent, symbol: "folder", open: open)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Label(name, systemImage: symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open(url) }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("placeRow")
                .contextMenu {
                    Button(ViewerText.revealInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
        }
        .onChange(of: expanded) { _, open in
            guard open, children == nil else { return }
            let url = url
            Task {
                children = await Task.detached(priority: .userInitiated) {
                    (try? FileSystemFolderLister().subfolders(of: url)) ?? []
                }.value
            }
        }
    }
}

/// „Ordner: Akten › Verträge (37 Dateien) ✕“ over the grid while a folder filter is on.
struct FolderFilterHeader: View {
    let model: any ViewerModel

    var body: some View {
        if let header = model.filterHeader {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                Text(header)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("folderFilterHeader")
                Button { model.clearFolderFilter() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(FieldIconButtonStyle())
                    .help(ViewerText.clearFolderFilter)
                    .accessibilityLabel(ViewerText.clearFolderFilter)
                    .accessibilityIdentifier("folderFilterClear")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}
