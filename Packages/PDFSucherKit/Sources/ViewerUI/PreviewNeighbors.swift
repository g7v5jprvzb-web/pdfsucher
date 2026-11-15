// PreviewNeighbors.swift — 1.3.4 Vorschau-Puffer
import Foundation
import OutputKit
import SearchKit

/// The pages the preview prepares around the focused one (spec 1.3.4, pure): the next in the direction the user
/// moves and one in the other direction. After ↓/↑ in the grid those are the pages ↓ and ↑ lead to; otherwise
/// (‹ ›, ← →, a click) the next and previous hit page.
enum PreviewNeighbors {
    static func pages(from old: PageRef?, to new: PageRef, hits: [DocumentHit], showAllPages: Bool) -> [PageRef] {
        let next = { (direction: FocusNavigator.Direction) in
            FocusNavigator.next(from: new, direction: direction, hits: hits, showAllPages: showAllPages)
        }
        let step = { (offset: Int) in FocusNavigator.step(from: new, by: offset, hits: hits) }
        let candidates: [PageRef?]
        if let old, old != new, FocusNavigator.next(from: old, direction: .down, hits: hits, showAllPages: showAllPages) == new {
            candidates = [next(.down), next(.up)]
        } else if let old, old != new, FocusNavigator.next(from: old, direction: .up, hits: hits, showAllPages: showAllPages) == new {
            candidates = [next(.up), next(.down)]
        } else if let old, old != new, FocusNavigator.step(from: old, by: -1, hits: hits) == new {
            candidates = [step(-1), step(1)]
        } else {
            candidates = [step(1), step(-1)]
        }
        var result: [PageRef] = []
        for case let ref? in candidates where ref != new && !result.contains(ref) { result.append(ref) }
        return result
    }
}
