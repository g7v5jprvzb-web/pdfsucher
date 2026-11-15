// SearchHistoryView.swift — 1.2.2 §1: arrow in the search field and the list of recent terms
import SwiftUI

/// ⌄ inside the search field next to „?“; ⌥↓ in the field opens the same list.
struct HistoryButton: View {
    let model: any ViewerModel
    let search: SearchFieldHandle
    @State private var shows = false

    var body: some View {
        Button { shows.toggle() } label: {
            Image(systemName: "chevron.down.circle")
        }
        .buttonStyle(FieldIconButtonStyle())
        .disabled(model.searchHistory.entries.isEmpty)      // grey only when there is nothing to show (1.2.4)
        .help("Letzte Suchbegriffe (⌥↓)")
        .accessibilityLabel(ViewerText.historyTitle)
        .accessibilityIdentifier("searchHistoryButton")
        .onAppear { search.openHistory = { shows = true } }
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            SearchHistoryList(history: model.searchHistory) { term in
                shows = false
                model.chooseHistoryEntry(term)
            }
        }
    }
}

/// Newest first; click or Return chooses, „Verlauf löschen“ at the end.
struct SearchHistoryList: View {
    let history: SearchHistory
    let choose: (String) -> Void
    @State private var selected: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.entries.isEmpty {
                Text(ViewerText.historyEmpty)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .accessibilityIdentifier("historyEmpty")
            } else {
                List(selection: $selected) {
                    ForEach(history.entries, id: \.self) { term in
                        Text(term)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { choose(term) }
                            .tag(term)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { choose(term) }
                            .accessibilityIdentifier("historyEntry")
                    }
                }
                .listStyle(.plain)
                .focused($listFocused)
                .onKeyPress(.return) {
                    guard let selected else { return .ignored }
                    choose(selected)
                    return .handled
                }
                .frame(height: min(CGFloat(history.entries.count) * 28 + 8, 320))
            }
            Divider()
            Button(ViewerText.historyClear) { history.clear() }
                .buttonStyle(.borderless)
                .disabled(history.entries.isEmpty)
                .padding(10)
                .accessibilityIdentifier("historyClear")
        }
        .frame(width: 300)
        // Not the toolbar's font or control size (review M5): the list is a normal popover.
        .font(.body)
        .controlSize(.regular)
        .onAppear {
            selected = history.entries.first
            listFocused = true
        }
    }
}
