import Foundation
import Testing
@testable import PDFSearch

/// Calls every callback from a background queue, like TCC and the Speech framework do.
private final class BackgroundFakeBackend: SpeechBackend, @unchecked Sendable {
    let speech: Bool, microphone: Bool, available: Bool
    let words: [String]
    var startError: Error?
    private(set) var stopped = 0

    init(speech: Bool = true, microphone: Bool = true, available: Bool = true, words: [String] = ["Rech", "Rechnung"]) {
        self.speech = speech; self.microphone = microphone; self.available = available; self.words = words
    }

    func requestSpeechAuthorization(_ done: @escaping @Sendable (Bool) -> Void) {
        let speech = speech
        DispatchQueue.global().async { done(speech) }
    }

    func requestMicrophone(_ done: @escaping @Sendable (Bool) -> Void) {
        let microphone = microphone
        DispatchQueue.global(qos: .utility).async { done(microphone) }
    }

    var isAvailable: Bool { available }

    func start(onResult: @escaping @Sendable (String?, Bool, Bool) -> Void) throws {
        if let startError { throw startError }
        let words = words
        DispatchQueue.global().async {
            for (i, w) in words.enumerated() { onResult(w, i == words.count - 1, false) }
        }
    }

    func stop() { stopped += 1 }
}

@MainActor
@Suite("Sprachsuche: Rückrufe von Hintergrund-Queues")
struct SpeechInputTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func textArrivesOnTheMainActorWithoutTrap() async {
        let backend = BackgroundFakeBackend()
        let input = SpeechInput(backend: backend)
        var received: [String] = []
        await input.start { text in
            MainActor.assertIsolated()
            received.append(text)
        }
        await waitUntil { received.last == "Rechnung" && !input.isListening }
        #expect(received == ["Rech", "Rechnung"])
        #expect(input.message == nil)
        #expect(!input.isListening, "endet nach dem letzten Ergebnis")
        #expect(backend.stopped >= 1)
    }

    @Test func deniedSpeechShowsGermanHint() async {
        let input = SpeechInput(backend: BackgroundFakeBackend(speech: false))
        await input.start { _ in Issue.record("kein Text erwartet") }
        #expect(input.message?.contains("Spracherkennung ist nicht erlaubt") == true)
        #expect(!input.isListening)
    }

    @Test func deniedMicrophoneShowsGermanHint() async {
        let input = SpeechInput(backend: BackgroundFakeBackend(microphone: false))
        await input.start { _ in }
        #expect(input.message?.contains("Mikrofon ist nicht erlaubt") == true)
    }

    @Test func unavailableRecognizer() async {
        let input = SpeechInput(backend: BackgroundFakeBackend(available: false))
        await input.start { _ in }
        #expect(input.message?.contains("nicht verfügbar") == true)
    }

    @Test func startFailureIsReported() async {
        let backend = BackgroundFakeBackend()
        backend.startError = CocoaError(.featureUnsupported)
        let input = SpeechInput(backend: backend)
        await input.start { _ in }
        #expect(input.message?.hasPrefix("Aufnahme konnte nicht starten") == true)
        #expect(!input.isListening)
    }
}
