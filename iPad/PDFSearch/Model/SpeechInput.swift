import AVFAudio
import Foundation
import Observation
import Speech

/// The system side of voice search. Every callback is `@Sendable` and may arrive on any queue
/// (TCC answers, recognition results and the audio tap come on background threads); none of them may be
/// main-actor isolated, or Swift 6 traps at run time (crash 2026-11-17: `requestAuthorization` callback).
protocol SpeechBackend: AnyObject, Sendable {
    func requestSpeechAuthorization(_ done: @escaping @Sendable (Bool) -> Void)
    func requestMicrophone(_ done: @escaping @Sendable (Bool) -> Void)
    var isAvailable: Bool { get }
    /// Starts listening; `onResult(text, isFinal, failed)` comes on any queue.
    func start(onResult: @escaping @Sendable (String?, Bool, Bool) -> Void) throws
    func stop()
}

/// Voice search: German speech to text; the live transcript goes to `onText` on the main actor.
@MainActor
@Observable
final class SpeechInput {
    private(set) var isListening = false
    private(set) var message: String?
    private let backend: any SpeechBackend

    init(backend: any SpeechBackend = SystemSpeechBackend()) {
        self.backend = backend
    }

    func toggle(onText: @escaping @MainActor (String) -> Void) {
        if isListening { stop() } else { Task { await start(onText: onText) } }
    }

    func start(onText: @escaping @MainActor (String) -> Void) async {
        message = nil
        let backend = backend
        let speechAllowed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            backend.requestSpeechAuthorization { c.resume(returning: $0) }
        }
        guard speechAllowed else { message = "Spracherkennung ist nicht erlaubt (Einstellungen › Apps › PDF Search)."; return }
        let micAllowed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            backend.requestMicrophone { c.resume(returning: $0) }
        }
        guard micAllowed else { message = "Mikrofon ist nicht erlaubt (Einstellungen › Apps › PDF Search)."; return }
        guard backend.isAvailable else { message = "Spracherkennung (Deutsch) ist gerade nicht verfügbar."; return }
        do {
            try backend.start { [weak self] text, isFinal, failed in
                Task { @MainActor in
                    if let text { onText(text) }
                    if isFinal || failed { self?.stop() }
                }
            }
            isListening = true
        } catch {
            message = "Aufnahme konnte nicht starten: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        backend.stop()
        isListening = false
    }
}

/// Speech framework + AVAudioEngine. Not main-actor isolated, so no closure made here inherits the main actor.
final class SystemSpeechBackend: SpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func requestSpeechAuthorization(_ done: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in done(status == .authorized) }
    }

    func requestMicrophone(_ done: @escaping @Sendable (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in done(granted) }
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func start(onResult: @escaping @Sendable (String?, Bool, Bool) -> Void) throws {
        guard let recognizer else { throw CocoaError(.featureUnsupported) }
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)  // audio thread
        }
        engine.prepare()
        try engine.start()
        let task = recognizer.recognitionTask(with: request) { result, error in
            onResult(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
        lock.withLock {
            self.engine = engine
            self.request = request
            self.task = task
        }
    }

    func stop() {
        let (engine, request, task) = lock.withLock { () -> (AVAudioEngine?, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            defer { self.engine = nil; self.request = nil; self.task = nil }
            return (self.engine, self.request, self.task)
        }
        guard engine != nil || task != nil else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
