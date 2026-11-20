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
        GeometryReader { proxy in
            // The bar reaches into the home-indicator area, so it takes as little height as possible.
            let overlap = max(0, min(16, proxy.safeAreaInsets.bottom - 18))
            VStack(spacing: 0) {
                ZStack {
                    tab(.library) { LibraryView() }
                    tab(.search) { SearchView() }
                    tab(.selection) { SelectionView() }
                }
                // Page and photo screens use the whole height; back is at the top left.
                if !(model.tab == .search && !model.searchPath.isEmpty) {
                    CompactTabBar()
                        .padding(.bottom, -overlap)
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .alert("Hinweis", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    /// Keeps every tab alive (scroll position, open page) and shows only the selected one.
    private func tab<Content: View>(_ id: AppModel.TabID, @ViewBuilder content: () -> Content) -> some View {
        let selected = model.tab == id
        return content()
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }
}

/// Flat bar at the bottom: icon and word side by side, about half as tall as the system tab bar.
struct CompactTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            item(.library, title: "Bibliothek", icon: "folder")
            item(.search, title: "Suche", icon: "magnifyingglass")
            item(.selection, title: "Auswahl", icon: "checklist", badge: model.selection.count)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
    }

    private func item(_ id: AppModel.TabID, title: String, icon: String, badge: Int = 0) -> some View {
        let selected = model.tab == id
        return Button {
            if selected, id == .search {
                // Tapping "Suche" again goes back to the list.
                model.searchPath.removeAll()
            }
            model.tab = id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Color.red))
                }
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
