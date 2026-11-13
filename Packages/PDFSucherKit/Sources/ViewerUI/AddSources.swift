// AddSources.swift — 1.2.1 §1: ask whether new sources are added or replace the loaded ones
import Foundation

/// Einstellungen → Allgemein „Beim Hinzufügen von Quellen“.
public enum AddSourcesPolicy: String, CaseIterable, Sendable {
    case ask, add, replace

    public var title: String {
        switch self {
        case .ask: "Fragen"
        case .add: "Immer zusätzlich"
        case .replace: "Immer ersetzen"
        }
    }
}

/// The buttons of the prompt.
public enum AddChoice: Sendable { case add, replace, cancel }

/// The sheet's content while it is shown.
public struct AddPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String

    /// - Parameters:
    ///   - newItems: names of the items that would really be added (not those already loaded or contained).
    ///   - existing: number of loaded sources (remembered missing ones included).
    ///   - id: kept when a second drop joins an open prompt, so the sheet stays.
    public init(newItems: [String], existing: Int, id: UUID = UUID()) {
        self.id = id
        title = newItems.count == 1 ? "„\(newItems[0])“ hinzufügen?" : "\(newItems.count) Objekte hinzufügen?"
        let old = existing == 1 ? "die bisherige Quelle" : "die bisherigen \(existing) Quellen"
        message = "Sollen die neuen Quellen zusätzlich durchsucht werden oder \(old) ersetzen?"
    }

    public static let addTitle = "Zusätzlich"
    public static let replaceTitle = "Ersetzen"
    public static let cancelTitle = "Abbrechen"
    public static let rememberTitle = "Nicht mehr fragen"
}
