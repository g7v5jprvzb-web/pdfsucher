import CoreGraphics
import PDFSearchCore
import SwiftUI
import UIKit

/// Screen 4: a JPEG hit with the found words outlined and the recognized text below.
struct PhotoScreen: View {
    @Environment(AppModel.self) private var model
    let fileID: Int64

    @State private var image: UIImage?
    @State private var analysis: ImageTextAnalysis?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let document = model.document(fileID) {
                VStack(spacing: 6) {
                    photo
                    details(document)
                }
                .toolbar { toolbar(document) }
                .task(id: fileID) { await load(document) }
            } else {
                ContentUnavailableView("Treffer nicht mehr vorhanden", systemImage: "photo.badge.exclamationmark",
                                       description: Text("Die Suche hat sich geändert."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder private var photo: some View {
        if let image {
            GeometryReader { geometry in
                let frame = Self.fittedRect(imageSize: image.size, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.85)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    ForEach(Array((analysis?.matches ?? []).enumerated()), id: \.offset) { _, match in
                        let box = CGRect(x: frame.minX + match.rect.minX * frame.width - 3,
                                         y: frame.minY + match.rect.minY * frame.height - 3,
                                         width: match.rect.width * frame.width + 6,
                                         height: match.rect.height * frame.height + 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.yellow.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.yellow, lineWidth: 2))
                            .frame(width: box.width, height: box.height)
                            .offset(x: box.minX, y: box.minY)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Foto mit \(analysis?.matches.count ?? 0) markierten Fundstellen")
        } else if loadFailed {
            ContentUnavailableView("Foto lässt sich nicht öffnen", systemImage: "exclamationmark.triangle")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ document: DocumentHit) -> some View {
        let selected = model.isSelected(fileID: document.fileID, page: 1)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Erkannter Text")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let analysis {
                    // Without a search term (list of all files) the first recognized lines are shown.
                    let searching = !model.result.terms.isEmpty
                    let lines = searching ? hitLines(analysis) : analysis.lines
                    if lines.isEmpty {
                        Text(searching ? "Der Begriff steht im Foto, ließ sich beim erneuten Lesen aber nicht genau verorten."
                                       : "In diesem Foto wurde kein Text erkannt.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.prefix(4).enumerated()), id: \.offset) { _, line in
                        Text(highlighted(line)).font(.subheadline).lineLimit(2)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))

            HStack(spacing: 6) {
                Button {
                    UIPasteboard.general.string = analysis?.lines.joined(separator: "\n")
                } label: {
                    Text("Text kopieren").frame(maxWidth: .infinity).frame(height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(analysis == nil)
                Button {
                    model.toggleSelection(document, page: 1)
                } label: {
                    Label(selected ? "Ausgewählt" : "Auswählen", systemImage: "checkmark")
                        .frame(maxWidth: .infinity).frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(selected ? Color.accentColor : Color.accentColor.opacity(0.18))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ToolbarContentBuilder
    private func toolbar(_ document: DocumentHit) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(document.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(document.totalHits > 0 ? "\(model.folderName(document.folderID)) · \(document.totalHits) Treffer"
                                            : model.folderName(document.folderID))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let url = model.url(of: document) {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Teilen")
            }
        }
    }

    private func load(_ document: DocumentHit) async {
        guard image == nil else { return }
        model.rememberQuery()
        guard let url = model.url(of: document) else { loadFailed = true; return }
        let terms = model.result.terms
        let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedPhoto in
            guard let cgImage = try? ImageLoading.cgImage(at: url, maxPixelSize: 2400) else { return LoadedPhoto(image: nil, analysis: nil) }
            let analysis = try? ImageTextLocator.analyze(cgImage, terms: terms)
            return LoadedPhoto(image: UIImage(cgImage: cgImage), analysis: analysis)
        }.value
        guard let loadedImage = loaded.image else { loadFailed = true; return }
        image = loadedImage
        analysis = loaded.analysis ?? ImageTextAnalysis(matches: [], lines: [])
    }

    private func hitLines(_ analysis: ImageTextAnalysis) -> [String] {
        let terms = model.result.terms
        return analysis.lines.filter { line in
            terms.contains { line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line)
        for term in model.result.terms where !term.isEmpty {
            var searchStart = line.startIndex
            while let found = line.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<line.endIndex) {
                if let lower = AttributedString.Index(found.lowerBound, within: text),
                   let upper = AttributedString.Index(found.upperBound, within: text) {
                    text[lower..<upper].backgroundColor = .yellow
                    text[lower..<upper].foregroundColor = .black
                }
                searchStart = found.upperBound
            }
        }
        return text
    }

    /// The rect of an aspect-fit image inside a container.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

private struct LoadedPhoto: @unchecked Sendable {
    let image: UIImage?
    let analysis: ImageTextAnalysis?
}
