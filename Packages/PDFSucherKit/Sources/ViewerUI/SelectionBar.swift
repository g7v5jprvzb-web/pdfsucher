// SelectionBar.swift — Task 4.3
import SwiftUI

/// "<n> Seiten ausgewählt  [Auswahl leeren] [Drucken] [Als PDF]"
struct SelectionBar: View {
    let model: any ViewerModel

    var body: some View {
        let count = model.selection.count
        HStack(spacing: 12) {
            Text(ViewerText.selection(count: count))
                .monospacedDigit()
                .accessibilityIdentifier("selectionCount")
            Spacer()
            if model.isPreparingPrint {
                ProgressView().controlSize(.small)
                Text(ViewerText.preparingPrint)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("preparingPrint")
            }
            Button("Auswahl leeren") { model.selection.clear() }
            Button("Drucken …") { model.printSelection() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.isPreparingPrint)
            Button("Als PDF …") { model.saveSelection() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isPreparingPrint)
        }
        .disabled(count == 0)
    }
}
