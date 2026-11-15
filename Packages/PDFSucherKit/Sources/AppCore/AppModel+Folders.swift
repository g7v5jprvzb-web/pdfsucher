// AppModel+Folders.swift — Ordnerleiste: tree, folder filter, places
import Foundation
import IndexKit
import SearchKit
import ViewerUI

extension AppModel {
    /// „Ordner: Akten › Verträge (37 Dateien)“ over the grid; nil without a filter.
    public var filterHeader: String? { folderFilter.header(tree: folderTree, shown: isBrowsing ? nil : hits.count) }

    /// A click (`adding` false) or ⌘-click (`adding` true) on a folder of the tree.
    public func selectFolder(_ folder: URL, adding: Bool) {
        var filter = folderFilter
        filter.select(folder, adding: adding)
        folderFilter = filter
    }

    /// The group „Einzelne Dateien“.
    public func selectSingleFiles(adding: Bool) {
        var filter = folderFilter
        filter.selectSingleFiles(sources.filter { !$0.isFolder }.map(\.url), adding: adding)
        folderFilter = filter
    }

    /// A whole filter at once (the sidebar's selection: one filter pass, not one per folder).
    public func setFolderFilter(_ filter: FolderFilter) { folderFilter = filter }

    /// ✕ in the header or „Alle Quellen“.
    public func clearFolderFilter() { folderFilter = FolderFilter() }

    /// A folder of „Orte“: inside a loaded source it filters at once; otherwise the add prompt (1.2.1) and,
    /// once it is loaded, the filter.
    public func openPlace(_ folder: URL) async {
        switch Places.action(for: folder, sources: sources) {
        case .filter(let url):
            selectFolder(url, adding: false)
        case .add(let url):
            // In line with drops and ⌘O (review I7): never two adds at once.
            pendingPlaceFilter = url.standardizedFileURL
            let previous = addTask
            let task = Task {
                await previous?.value
                await requestAdd([url])
                if addPrompt == nil { finishPendingPlace() }    // added at once (no prompt, policy)
            }
            addTask = task
            await task.value
        }
    }

    /// After the place's add (or its prompt's answer): filter to it if it is loaded now; either way nothing
    /// stays waiting for a later, unrelated add (review I7).
    func finishPendingPlace() {
        applyPendingPlaceFilter()
        pendingPlaceFilter = nil
    }

    /// Filters to a place clicked before it was loaded, once a source covers it.
    func applyPendingPlaceFilter() {
        guard let place = pendingPlaceFilter else { return }
        guard case .filter = Places.action(for: place, sources: sources) else { return }
        pendingPlaceFilter = nil
        selectFolder(place, adding: false)
    }

    /// The tree from the files of the document list (the browse list; no disk access).
    /// `checkFilter`: a fresh list from the indexes (`refreshFolderTree`), so the tree may decide whether
    /// chosen folders still exist; an older list (a source removed) leaves that to the next one (re-review).
    func rebuildFolderTree(files: [URL], checkFilter: Bool = false) {
        browseFiles = files
        // The counts follow „Dateitypen“; the folders shown do not (a folder with only hidden kinds shows 0).
        let kinds = FileKindFilter(kinds: settings.fileKinds)
        folderTree = FolderTree.build(sources: sources, files: files, counts: kinds.isAll ? { _ in true } : { url in
            DocumentKind(fileExtension: url.pathExtension).map(kinds.includes) ?? false
        })
        if checkFilter { dropFilteredFoldersGoneFromDisk() }
        // „Einzelne Dateien“ chosen: it covers the single files loaded now, also ones added later.
        if !folderFilter.singleFiles.isEmpty {
            var filter = folderFilter
            filter.selectSingleFiles(sources.filter { !$0.isFolder }.map(\.url), adding: false)
            for folder in folderFilter.folders { filter.select(folder, adding: true) }
            if filter != folderFilter { folderFilter = filter }
        }
    }

    /// After a successful run following a change on disk: a chosen folder the tree no longer has (renamed,
    /// also only in case, deleted, emptied) no longer filters; an empty grid with a filter on a folder the
    /// tree does not show would look like a fault. The tree decides, not the disk: no disk access here.
    private func dropFilteredFoldersGoneFromDisk() {
        guard !checkFilterAfterTree.isEmpty else { return }
        let roots = checkFilterAfterTree
        checkFilterAfterTree = []
        var filter = folderFilter
        for folder in folderFilter.folders where roots.contains(where: { folder.path == $0 || folder.path.hasPrefix($0 + "/") }) {
            if FolderTree.path(to: folder, in: folderTree) == nil { filter.select(folder, adding: true) }   // toggles it off
        }
        if filter != folderFilter { folderFilter = filter }
    }

    /// Sources removed: their folders leave the tree and the filter.
    func sourcesChangedForFolders() {
        rebuildFolderTree(files: browseFiles)              // removed roots go at once (files outside sources are ignored)
        refreshFolderTree()
        var filter = folderFilter
        for folder in filter.folders where Places.action(for: folder, sources: sources) != .filter(folder) {
            filter.select(folder, adding: true)            // toggles it off
        }
        filter.keepSingleFiles(Set(sources.filter { !$0.isFolder }.map { $0.url.standardizedFileURL.path }))
        folderFilter = filter
    }
}
