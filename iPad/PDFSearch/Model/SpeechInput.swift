import AVFAudio
import Foundation
import Observation
import Speech

/// Voice search: German speech to text with the Speech framework; the live transcript goes to `onText`.
@MainActor
@Observable
final class SpeechInput {
    private(set) var isListening = false
    private(set) var message: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle(onText: @escaping @MainActor (String) -> Void) {
        if isListening { stop() } else { Task { await start(onText: onText) } }
    }

    private func start(onText: @escaping @MainActor (String) -> Void) async {
        message = nil
        let speechStatus = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { message = "Spracherkennung ist nicht erlaubt (Einstellungen › PDF Search)."; return }
        guard await AVAudioApplication.requestRecordPermission() else { message = "Mikrofon ist nicht erlaubt (Einstellungen › PDF Search)."; return }
        guard let recognizer, recognizer.isAvailable else { message = "Spracherkennung (Deutsch) ist gerade nicht verfügbar."; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            Self.installTap(on: engine.inputNode, request: request)
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            isListening = true
            task = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    if let text { onText(text) }
                    if final || failed { self.stop() }
                }
            }
        } catch {
            message = "Aufnahme konnte nicht starten: \(error.localizedDescription)"
            stop()
        }
    }

    /// Nonisolated so the tap closure is not main-actor isolated (it runs on the audio thread).
    nonisolated private static func installTap(on node: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest) {
        let format = node.outputFormat(forBus: 0)
        nonisolated(unsafe) let request = request
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
