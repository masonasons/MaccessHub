import AVFoundation
import Foundation

enum AVSpeechVoiceList {
    static func voices() -> [SpeechVoices.Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                let locale = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                return SpeechVoices.Voice(identifier: voice.identifier, title: "\(voice.name) (\(locale))")
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
