import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.showFolderTree) private var showTree = true
    @AppStorage(SettingsKey.previewOnLeft) private var previewOnLeft = false
    @AppStorage(SettingsKey.tileSize) private var tileSize = 80.0
    @State private var showFolders = false
    @State private var fullScreenPreview = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(showTree: $showTree, previewOnLeft: $previewOnLeft, showFolders: $showFolders)
            Divider()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if showTree && !fullScreenPreview {
                        FolderTreeView()
                            .frame(width: 250)
                            .transition(.move(edge: .leading))
                        Divider()
                    }
                    if fullScreenPreview {
                        PreviewPane(fullScreen: $fullScreenPreview)
                    } else if previewOnLeft {
                        PreviewPane(fullScreen: $fullScreenPreview)
                            .frame(width: previewWidth(geo.size.width))
                        Divider()
                        ResultsView(tileSize: $tileSize, showFolders: $showFolders)
                    } else {
                        ResultsView(tileSize: $tileSize, showFolders: $showFolders)
                        Divider()
                        PreviewPane(fullScreen: $fullScreenPreview)
                            .frame(width: previewWidth(geo.size.width))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTree)
        .animation(.easeInOut(duration: 0.2), value: previewOnLeft)
        .animation(.easeInOut(duration: 0.2), value: fullScreenPreview)
        .sheet(isPresented: $showFolders) { FoldersIndexView() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enteredBackground()
            case .active: model.becameActive()
            default: break
            }
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "demoShowFolders") { showFolders = true }
        }
    }

    private func previewWidth(_ total: CGFloat) -> CGFloat {
        let rest = total - (showTree ? 251 : 0)
        return max(320, rest * 0.46)
    }
}
