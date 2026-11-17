import AVFoundation
import Foundation
import Observation
import Speech

/// Voice search: speech is turned into text on the device (German), live while speaking.
@MainActor
@Observable
final class VoiceInput {
    private(set) var isListening = false
    var errorMessage: String?

    private var session: RecognitionSession?

    /// Starts listening; `onText` receives the transcript so far, repeatedly.
    func start(onText: @escaping @MainActor @Sendable (String) -> Void) async {
        guard !isListening else { return }
        guard await RecognitionSession.requestSpeechPermission() else {
            errorMessage = "Spracherkennung ist nicht erlaubt. Einstellungen > Apps > PDF Search > Spracherkennung."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Mikrofon ist nicht erlaubt. Einstellungen > Apps > PDF Search > Mikrofon."
            return
        }
        do {
            session = try RecognitionSession.start { text, isFinal, failed in
                Task { @MainActor in
                    if !text.isEmpty { onText(text) }
                    if isFinal || failed { self.stop() }
                }
            }
            isListening = true
        } catch {
            errorMessage = "Spracheingabe ist gerade nicht verfügbar."
            stop()
        }
    }

    func stop() {
        session?.stop()
        session = nil
        isListening = false
    }

    func toggle(onText: @escaping @MainActor @Sendable (String) -> Void) {
        if isListening {
            stop()
        } else {
            Task { await start(onText: onText) }
        }
    }
}

enum VoiceError: Error {
    case unavailable
}

/// Audio engine + speech request. Its callbacks run on audio and recognition threads, so it is
/// deliberately not tied to the main actor; it is only started and stopped from there.
final class RecognitionSession: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    private init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    static func requestSpeechPermission() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    /// `handler(text, isFinal, failed)` is called on a background thread.
    static func start(handler: @escaping @Sendable (String, Bool, Bool) -> Void) throws -> RecognitionSession {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")), recognizer.isAvailable else {
            throw VoiceError.unavailable
        }
        let session = RecognitionSession(recognizer: recognizer)
        session.request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            session.request.requiresOnDeviceRecognition = true
        }

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let input = session.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            session.request.append(buffer)
        }
        session.engine.prepare()
        try session.engine.start()

        session.task = recognizer.recognitionTask(with: session.request) { result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            handler(text, result?.isFinal ?? false, error != nil)
        }
        return session
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.finish()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
