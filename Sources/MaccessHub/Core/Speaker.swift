import AppKit
import AVFoundation
import Foundation
import os

/// Where spoken messages go.
enum SpeechOutput: String, Codable, CaseIterable, Identifiable {
    /// VoiceOver when it is running, otherwise the system voice.
    case automatic
    case voiceOver
    case systemVoice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "VoiceOver when running, otherwise system voice"
        case .voiceOver: return "VoiceOver only"
        case .systemVoice: return "System voice only"
        }
    }
}

/// Speaks short messages through VoiceOver (so they use the user's own voice
/// and interrupt correctly) or through AVSpeechSynthesizer as a fallback.
final class Speaker {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "speech")
    private let synthesizer = AVSpeechSynthesizer()

    var output: SpeechOutput = .automatic
    /// 0...1, mapped onto AVSpeechUtterance's rate range for the system voice.
    var rate: Double = 0.5
    var volume: Double = 1.0
    /// Identifier of an AVSpeechSynthesisVoice; nil for the system default.
    var voiceIdentifier: String?
    /// When set, messages go here instead of being spoken (used by `--report`).
    var sink: ((String) -> Void)?

    static var isVoiceOverRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
    }

    func speak(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if let sink { sink(message); return }
        DispatchQueue.main.async { [self] in
            switch output {
            case .voiceOver:
                if !speakWithVoiceOver(message) { speakWithSystemVoice(message) }
            case .automatic:
                if Self.isVoiceOverRunning, speakWithVoiceOver(message) { return }
                speakWithSystemVoice(message)
            case .systemVoice:
                speakWithSystemVoice(message)
            }
        }
    }

    private func speakWithVoiceOver(_ text: String) -> Bool {
        guard Self.isVoiceOverRunning else { return false }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"VoiceOver\" to output \"\(escaped)\""
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            log.error("VoiceOver output failed: \(error)")
            return false
        }
        return true
    }

    private func speakWithSystemVoice(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        let range = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + Float(rate) * range
        utterance.volume = Float(volume)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }
}
