// TrialRun.swift — debug-only scripted trial of the folder bar (no XCUITest, no screen-recording permission)
#if DEBUG
import AppCore
import AppKit
import Foundation
import SearchKit
import ViewerUI

/// `-trialDir <dir>` with `-uiTestFolders`: shows the folder bar, measures how fast the tree and the filter
/// are, saves window snapshots into <dir>, waits for `<dir>/changed` (files renamed or deleted from outside),
/// records the tree again, writes `<dir>/trial.json` and quits. Read-only for the folders.
@MainActor enum TrialRun {
    static func run(model: AppModel, dir: URL) async {
        let clock = ContinuousClock()
        var log: [String: Any] = [:]
        model.folderBar.isVisible = true
        let start = clock.now
        while model.folderTree.isEmpty, clock.now - start < .seconds(120) { try? await Task.sleep(for: .milliseconds(20)) }
        log["treeVisibleMs"] = ms(clock.now - start)
        while model.indexStatus != .upToDate, clock.now - start < .seconds(600) {
            if case .problems = model.indexStatus { break }
            if case .recognizing = model.indexStatus { break }           // phase 2 runs on in the background
            try? await Task.sleep(for: .milliseconds(100))
        }
        log["indexPhase1Ms"] = ms(clock.now - start)
        try? await Task.sleep(for: .seconds(2))
        log["roots"] = model.folderTree.map { ["name": $0.name, "files": $0.fileCount, "folders": count($0) - 1] }
        snapshot(dir.appendingPathComponent("1-baum.png"))

        // The biggest subfolder: filter time (browsing, then with a search term).
        if let biggest = model.folderTree.first?.children.max(by: { $0.fileCount < $1.fileCount }) {
            let t = clock.now
            model.selectFolder(biggest.url, adding: false)
            log["filterMs"] = ms(clock.now - t)
            log["filtered"] = ["folder": biggest.name, "files": biggest.fileCount, "shown": model.hits.count]
            try? await Task.sleep(for: .seconds(1))
            snapshot(dir.appendingPathComponent("2-gefiltert.png"))
            model.queryText = "rechnung"
            try? await Task.sleep(for: .seconds(2))
            log["searchHeader"] = model.filterHeader ?? "-"
            snapshot(dir.appendingPathComponent("3-gefiltert-suche.png"))
            model.queryText = ""
            model.clearFolderFilter()
        }

        // Outside changes (the shell renames and deletes in a copy, then writes `changed`): no activation,
        // the folder watcher alone must bring the tree up to date.
        let before = names(model)
        try? "ready".write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        await waitForFile(dir.appendingPathComponent("changed"), seconds: 120)
        let changedAt = clock.now
        while names(model) == before, clock.now - changedAt < .seconds(20) { try? await Task.sleep(for: .milliseconds(50)) }
        log["treeFollowedMs"] = names(model) == before ? -1 : ms(clock.now - changedAt)
        log["afterChange"] = names(model)
        snapshot(dir.appendingPathComponent("4-nach-aenderung.png"))

        // Volumes (`-trialVolume <mount point>`): the shell ejects it, then mounts it again.
        if let volume = UserDefaults.standard.string(forKey: "trialVolume") {
            log["volumeBefore"] = volumeState(model, volume)
            try? "ready".write(to: dir.appendingPathComponent("ready-eject"), atomically: true, encoding: .utf8)
            await waitForFile(dir.appendingPathComponent("ejected"), seconds: 120)
            try? await Task.sleep(for: .seconds(6))
            log["volumeEjected"] = volumeState(model, volume)
            snapshot(dir.appendingPathComponent("5-ausgeworfen.png"))
            try? "ready".write(to: dir.appendingPathComponent("ready-mount"), atomically: true, encoding: .utf8)
            await waitForFile(dir.appendingPathComponent("mounted"), seconds: 120)
            try? await Task.sleep(for: .seconds(6))
            log["volumeMounted"] = volumeState(model, volume)
            snapshot(dir.appendingPathComponent("6-wieder-eingehaengt.png"))
        }

        if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("trial.json"))
        }
        NSApp.terminate(nil)
    }

    private static func waitForFile(_ url: URL, seconds: Int) async {
        let start = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now - start < .seconds(seconds) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The volume's root in the tree, the index status, the hint and how many shown files lie on it.
    private static func volumeState(_ model: AppModel, _ volume: String) -> [String: Any] {
        let root = model.folderTree.first { $0.url.path.hasPrefix(volume) }
        return ["inTree": root.map { "\($0.name) \($0.fileCount) \($0.children.map(\.name))" } ?? "-",
                "indexStatus": String(describing: model.indexStatus),
                "notice": model.notice ?? "-",
                "hitsOnVolume": model.hits.filter { $0.url.path.hasPrefix(volume) }.count,
                "sources": model.sources.map(\.url.path)]
    }

    private static func count(_ node: FolderNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }

    private static func names(_ model: AppModel) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: model.folderTree.map { ($0.name, $0.children.map { "\($0.name) \($0.fileCount)" }) })
    }

    private static func ms(_ d: Duration) -> Int { Int(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }

    private static func snapshot(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) ?? NSApp.mainWindow,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
