import SwiftUI

/// The shared places as an expandable folder tree; the selection filters the search.
struct FolderTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ordner").font(.headline)
                Spacer()
                if model.selection != nil {
                    Button("Alle") { model.selection = nil }.font(.subheadline)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.places) { place in
                        FolderNodeRow(placeID: place.id, url: place.url, relativePath: "", name: place.place.name,
                                      depth: 0, isPlace: true)
                    }
                }
                .padding(.horizontal, 6)
            }
            .opacity(model.wholeIPad ? 0.45 : 1)
            .disabled(model.wholeIPad)

            Divider()
            IndexStatusFooter()
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct FolderNodeRow: View {
    @Environment(AppModel.self) private var model
    let placeID: UUID
    let url: URL
    let relativePath: String
    let name: String
    let depth: Int
    let isPlace: Bool
    @State private var expanded = false
    @State private var children: [(name: String, url: URL)]?

    private var me: FolderSelection { FolderSelection(placeID: placeID, relativePath: relativePath) }
    private var isSelected: Bool { model.selection == me }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    expanded.toggle()
                    if expanded && children == nil { children = Self.subfolders(of: url) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 18, height: 28)
                        .opacity(children?.isEmpty == true ? 0.2 : 1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    model.selection = isSelected ? nil : me
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isPlace ? (placeID == SharedPlace.builtInID ? "ipad" : "externaldrive.connected.to.line.below") : "folder")
                            .foregroundStyle(Color.accentColor)
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 14)

            if expanded, let children {
                ForEach(children, id: \.url) { child in
                    FolderNodeRow(placeID: placeID, url: child.url,
                                  relativePath: relativePath.isEmpty ? child.name : relativePath + "/" + child.name,
                                  name: child.name, depth: depth + 1, isPlace: false)
                }
            }
        }
        .font(.subheadline)
    }

    static func subfolders(of url: URL) -> [(name: String, url: URL)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { item -> (String, URL)? in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }
            return (item.lastPathComponent, item)
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}

struct IndexStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isIndexing {
                if let fraction = model.progressFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(model.progressText).font(.caption2).lineLimit(2)
            } else {
                Label(model.indexStatus, systemImage: "checkmark.circle")
                    .font(.caption)
                if !model.unreadable.isEmpty {
                    Label("\(model.unreadable.count) nicht lesbar", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
