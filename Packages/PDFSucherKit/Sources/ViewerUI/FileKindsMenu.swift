// FileKindsMenu.swift — 1.3 Teil B Task 11 (spec 1.3 §8a „Dateitypen“)
import IndexKit
import SwiftUI

/// The „Dateitypen“ menu in the view controls line: a tick per kind, any combination; the last ticked kind
/// cannot be unticked. Below: „Nur …“ per kind and „Alle Dateitypen zeigen“, each one click. Font and control
/// size come from `ToolbarArea` (`toolbarFontSize`), none of its own.
struct FileKindsMenu: View {
    @Bindable var settings: GridSettings

    var body: some View {
        Menu(ViewerText.fileKindsTitle(settings.fileKinds)) {
            ForEach(GridSettings.allFileKinds, id: \.self) { kind in
                Toggle(ViewerText.fileKindLabel(kind), isOn: Binding(
                    get: { settings.fileKinds.contains(kind) },
                    set: { _ in settings.toggleFileKind(kind) }))
                    .disabled(settings.fileKinds == [kind])
            }
            Divider()
            ForEach(GridSettings.allFileKinds, id: \.self) { kind in
                Button(ViewerText.onlyFileKind(kind)) { settings.showOnlyFileKind(kind) }
                    .disabled(settings.fileKinds == [kind])
            }
            Button(ViewerText.showAllFileKinds) { settings.showAllFileKinds() }
                .disabled(settings.fileKinds.isSuperset(of: GridSettings.allFileKinds))
        }
        .fixedSize()
        .help(ViewerText.fileKindsHelp)
        .accessibilityLabel(ViewerText.fileKindsMenu)
        .accessibilityValue(ViewerText.fileKindsTitle(settings.fileKinds))
        .accessibilityIdentifier("fileKindsMenu")
    }
}

/// Empty grid while the „Dateitypen“ filter hides every result: says so and offers all kinds again.
struct HiddenByFilterView: View {
    let count: Int
    let browsing: Bool
    @Bindable var settings: GridSettings

    var body: some View {
        ContentUnavailableView {
            Label(ViewerText.hiddenByFilter(count, browsing: browsing), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(ViewerText.hiddenByFilterDetail(settings.fileKinds))
        } actions: {
            Button(ViewerText.showAllFileKinds) { settings.showAllFileKinds() }
                .accessibilityIdentifier("showAllFileKinds")
        }
        .accessibilityIdentifier("hiddenByFilter")
    }
}
