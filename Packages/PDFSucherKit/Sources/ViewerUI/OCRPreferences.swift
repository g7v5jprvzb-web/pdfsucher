// OCRPreferences.swift — 1.2 (spec 1.2 §7)
import Foundation
import Observation

/// „Texterkennung (OCR)“ and „Bilder durchsuchen (PNG, JPEG, HEIC, DNG)“, both on by default, persisted.
@MainActor @Observable public final class OCRPreferences {
    enum Key {
        static let recognizeText = "ocr.recognizeText"
        static let includeImages = "ocr.includeImages"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedRecognizeText: Bool
    private var storedIncludeImages: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedRecognizeText = defaults.object(forKey: Key.recognizeText) == nil ? true : defaults.bool(forKey: Key.recognizeText)
        storedIncludeImages = defaults.object(forKey: Key.includeImages) == nil ? true : defaults.bool(forKey: Key.includeImages)
    }

    public var recognizeText: Bool {
        get { storedRecognizeText }
        set { storedRecognizeText = newValue; defaults.set(newValue, forKey: Key.recognizeText) }
    }

    public var includeImages: Bool {
        get { storedIncludeImages }
        set { storedIncludeImages = newValue; defaults.set(newValue, forKey: Key.includeImages) }
    }
}
