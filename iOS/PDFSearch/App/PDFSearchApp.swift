import SwiftUI

@main
struct PDFSearchApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.load()
                    #if DEBUG
                    await model.runDemoIfRequested()
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the app: pick up files added or changed in the meantime.
                    if phase == .active { model.refreshAllIfLoaded() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Bibliothek", systemImage: "folder", value: AppModel.TabID.library) {
                LibraryView()
            }
            Tab("Suche", systemImage: "magnifyingglass", value: AppModel.TabID.search) {
                SearchView()
            }
            Tab("Auswahl", systemImage: "checklist", value: AppModel.TabID.selection) {
                SelectionView()
            }
            .badge(model.selection.count)
        }
        // Platz sparen: die Tab-Leiste wird beim Scrollen nach unten kleiner.
        .tabBarMinimizeBehavior(.onScrollDown)
        .alert("Hinweis", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// The blue magnifier at the top right of every screen: searches all folders.
struct GlobalSearchButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.startGlobalSearch()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ganzes iPhone durchsuchen")
    }
}
