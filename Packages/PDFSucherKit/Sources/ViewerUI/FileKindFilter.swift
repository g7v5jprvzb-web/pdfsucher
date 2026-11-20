// FileKindFilter.swift — 1.3 Teil B Task 11 (spec 1.3 §8a „Dateitypen“)
import IndexKit
import SearchKit

/// Shows only documents of the chosen kinds (PDF, Word, PowerPoint, Bilder). Pure: no state, no UI.
/// A predicate on `DocumentHit` with `includes`/`label`, so it can join further grid filters (e.g. the
/// 1.3.1 folder filter), which combine with AND.
public struct FileKindFilter: Sendable, Equatable {
    /// Never empty: an empty set means every kind (a filter never hides everything).
    public let kinds: Set<DocumentKind>

    public init(kinds: Set<DocumentKind>) {
        self.kinds = kinds.isEmpty ? Set(GridSettings.allFileKinds) : kinds
    }

    /// Every kind: hides nothing.
    public static let all = FileKindFilter(kinds: Set(GridSettings.allFileKinds))

    public var isAll: Bool { kinds.isSuperset(of: GridSettings.allFileKinds) }

    public func includes(_ kind: DocumentKind) -> Bool { kinds.contains(kind) }

    public func includes(_ hit: DocumentHit) -> Bool { includes(hit.kind) }

    /// The hits of the chosen kinds, in their order.
    public func apply(_ hits: [DocumentHit]) -> [DocumentHit] {
        isAll ? hits : hits.filter { kinds.contains($0.kind) }
    }

    /// „Dateitypen“ when every kind is on, else the chosen kinds („PDF, Word“).
    public var label: String { ViewerText.fileKindsTitle(kinds) }
}

/// Search field shortcut for the file types: `typ:word` (also `type:` and `ext:`, any case; several values
/// with commas, `typ:word,pdf`, or several tokens). Values are the kind names (`pdf`, `word`, `powerpoint`,
/// `bild`, `bilder`, `image`) or a file extension (`docx`, `ppt`, `jpg`, …). A token with an unknown value
/// stays search text. Pure: the model searches `rest` and shows only `kinds` (nil: no shortcut typed).
public enum KindQuery {
    public static func split(_ text: String) -> (kinds: Set<DocumentKind>?, rest: String) {
        var kinds = Set<DocumentKind>()
        var rest: [Substring] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            if let found = self.kinds(in: token) { kinds.formUnion(found) } else { rest.append(token) }
        }
        return (kinds.isEmpty ? nil : kinds, kinds.isEmpty ? text : rest.joined(separator: " "))
    }

    private static let prefixes = ["typ:", "type:", "ext:"]
    private static let names: [String: DocumentKind] = [
        "pdf": .pdf, "word": .word, "powerpoint": .powerpoint, "ppt": .powerpoint, "bild": .image, "bilder": .image, "image": .image,
    ]

    /// The kinds of a shortcut token; nil when it is none or names an unknown kind.
    private static func kinds(in token: Substring) -> Set<DocumentKind>? {
        let lower = token.lowercased()
        guard let prefix = prefixes.first(where: lower.hasPrefix) else { return nil }
        let values = lower.dropFirst(prefix.count).split(separator: ",")
        let found = values.map { names[String($0)] ?? DocumentKind(fileExtension: String($0)) }
        guard !found.isEmpty, !found.contains(nil) else { return nil }
        return Set(found.compactMap { $0 })
    }
}
