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
