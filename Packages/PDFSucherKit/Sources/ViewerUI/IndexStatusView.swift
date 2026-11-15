// IndexStatusView.swift — Task 4.3
import SwiftUI

/// "Gefunden in … · Index: …"; the problems status opens a list of unreadable files.
struct IndexStatusView: View {
    let model: any ViewerModel
    @State private var showsProblems = false
    /// „Suche läuft…“ appears only when a search takes longer than `searchingDelay`, so fast searches
    /// do not flicker.
    @State private var showsSearching = false
    static let searchingDelay: Duration = .milliseconds(200)

    var body: some View {
        HStack(spacing: 6) {
            if showsSearching {
                ProgressView().controlSize(.small)
                Text(ViewerText.searching)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("searching")
                Text("·").foregroundStyle(.secondary)
            }
            if !model.summary.isEmpty {
                Text(model.summary)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("summary")
            }
            if let status = ViewerText.indexStatus(model.indexStatus, recognitionOn: model.ocrPreferences.recognizeText) {
                if !model.summary.isEmpty { Text("·").foregroundStyle(.secondary) }
                switch model.indexStatus {
                case .building:
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                case .layingOut:
                    // No ✕ of its own: removing the source, the Word/PowerPoint switch or quitting stops it.
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                        .accessibilityIdentifier("layoutStatus")
                case .recognizing:
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                        .accessibilityIdentifier("recognitionStatus")
                    Button { model.stopRecognition() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Texterkennung anhalten (Erkanntes bleibt erhalten)")
                        .accessibilityLabel("Texterkennung anhalten")
                case .problems(let failed, let noText):
                    Button(status) { showsProblems = true }
                        .buttonStyle(.link)
                        .help("Liste der nicht lesbaren Dateien anzeigen")
                        .popover(isPresented: $showsProblems, arrowEdge: .bottom) {
                            ProblemList(failed: failed, noText: noText, recognitionOn: model.ocrPreferences.recognizeText)
                        }
                case .unreachable:
                    Label(status, systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                default:
                    Text(status).foregroundStyle(.secondary)
                }
            }
            if model.isRecognitionStopped {
                Text("·").foregroundStyle(.secondary)
                Text(ViewerText.recognitionStopped).foregroundStyle(.secondary)
                Button(ViewerText.resumeRecognition) { model.resumeRecognition() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("resumeRecognition")
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("notice")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: model.settings.effectiveToolbarFontSize - 1))     // „callout“ of the toolbar size (1.2.2)
        .lineLimit(3)                                       // 1.2.2 §2: wraps at a large font instead of cutting off
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.isSearching) {
            guard model.isSearching else { showsSearching = false; return }
            do { try await Task.sleep(for: Self.searchingDelay) } catch { return }
            showsSearching = model.isSearching
        }
    }
}

private struct ProblemList: View {
    let failed: [String]
    let noText: [String]
    var recognitionOn = true

    var body: some View {
        List {
            if !failed.isEmpty {
                Section(ViewerText.unreadableSection) {
                    ForEach(failed, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
            if !noText.isEmpty {
                Section(ViewerText.noTextSection(recognitionOn: recognitionOn)) {
                    ForEach(noText, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 460, minHeight: 200, idealHeight: 320)
    }
}
