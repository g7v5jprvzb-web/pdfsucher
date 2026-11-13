// AddSourcesSheet.swift — 1.2.1 §1
import SwiftUI

/// „<Name> hinzufügen?“: Zusätzlich (Return), Ersetzen, Abbrechen (Esc), „Nicht mehr fragen“.
struct AddSourcesSheet: View {
    let prompt: AddPrompt
    let answer: (AddChoice, Bool) -> Void
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt.title).font(.headline)
                    Text(prompt.message).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(AddPrompt.rememberTitle, isOn: $remember)
                .accessibilityIdentifier("addPrompt.remember")
            HStack {
                Spacer()
                Button(AddPrompt.cancelTitle, role: .cancel) { answer(.cancel, false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("addPrompt.cancel")
                Button(AddPrompt.replaceTitle) { answer(.replace, remember) }
                    .accessibilityIdentifier("addPrompt.replace")
                Button(AddPrompt.addTitle) { answer(.add, remember) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("addPrompt.add")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
