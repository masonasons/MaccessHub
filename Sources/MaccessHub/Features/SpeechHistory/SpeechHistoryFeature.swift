import AppKit
import Observation

/// Keeps a bounded history of VoiceOver speech that can be reviewed, copied
/// and recorded, like the Speech History add-on for NVDA.
@MainActor
@Observable
final class SpeechHistoryFeature {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    /// Oldest first.
    private(set) var history: [Entry] = []
    /// Review position in `history`; nil means the newest entry.
    private(set) var selectedIndex: Int?
    private(set) var recordedItems: [String] = []
    private(set) var isRecording = false

    var maximumHistoryLength = 500 {
        didSet { enforceLimit() }
    }
    @ObservationIgnored var trimLeadingWhitespace = true
    @ObservationIgnored var trimTrailingWhitespace = true
    /// Captured speech is dropped while this is true, e.g. while the user reads
    /// the history window, so reviewing history does not add to it.
    @ObservationIgnored var isPaused: () -> Bool = { false }

    @ObservationIgnored private let speaker: Speaker
    /// Text MaccessHub itself just sent to VoiceOver, which VoiceOver will echo
    /// back as its last phrase. Matched once, then dropped.
    @ObservationIgnored private var suppressed: [(text: String, expires: Date)] = []
    private static let suppressionWindow: TimeInterval = 3

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    // MARK: Capture

    /// Adds a phrase VoiceOver spoke. Returns whether it was stored.
    @discardableResult
    func capture(_ phrase: String, at now: Date = Date()) -> Bool {
        var text = phrase
        if trimLeadingWhitespace { text = String(text.drop(while: \.isWhitespace)) }
        if trimTrailingWhitespace { text = String(text.reversed().drop(while: \.isWhitespace).reversed()) }
        guard !text.allSatisfy(\.isWhitespace), !isPaused(), !consumeSuppression(of: phrase, at: now) else { return false }

        history.append(Entry(text: text))
        enforceLimit()
        selectedIndex = nil
        if isRecording { recordedItems.append(text) }
        return true
    }

    private func consumeSuppression(of phrase: String, at now: Date) -> Bool {
        suppressed.removeAll { $0.expires < now }
        let key = Self.normalized(phrase)
        guard let index = suppressed.firstIndex(where: { $0.text == key }) else { return false }
        suppressed.remove(at: index)
        return true
    }

    private func enforceLimit() {
        let excess = history.count - max(1, maximumHistoryLength)
        guard excess > 0 else { return }
        history.removeFirst(excess)
        if let selected = selectedIndex { selectedIndex = selected >= excess ? selected - excess : nil }
    }

    /// Speaks without the echo landing back in history.
    func say(_ text: String, at now: Date = Date()) {
        suppressed.append((Self.normalized(text), now + Self.suppressionWindow))
        speaker.speak(text)
    }

    // Speaker trims before output, so compare trimmed text.
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Review

    private var currentIndex: Int? {
        history.isEmpty ? nil : selectedIndex ?? history.count - 1
    }

    var current: Entry? { currentIndex.map { history[$0] } }

    func previous() { step(by: -1) }
    func next() { step(by: 1) }

    private func step(by delta: Int) {
        guard let index = currentIndex else { say("No speech history"); return }
        let target = index + delta
        guard history.indices.contains(target) else {
            // Stay put and say where we are, so the edge is audible.
            say("\(delta < 0 ? "Oldest" : "Newest"): \(history[index].text)")
            return
        }
        selectedIndex = target == history.count - 1 ? nil : target
        say(history[target].text)
    }

    /// Selects a specific entry, e.g. from the history window.
    func select(_ id: Entry.ID?) {
        guard let id, let index = history.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index == history.count - 1 ? nil : index
    }

    func copyCurrent() {
        guard let entry = current else { say("No speech history"); return }
        Self.copyToPasteboard(entry.text)
        say("Copied")
    }

    /// The whole history, oldest first, one announcement per line.
    var allText: String { history.map(\.text).joined(separator: "\n") }

    func clear() {
        clearSilently()
        say("Speech history cleared")
    }

    func clearSilently() {
        history.removeAll()
        selectedIndex = nil
    }

    // MARK: Recording

    func startRecording() {
        recordedItems.removeAll()
        isRecording = true
        say("Started recording speech")
    }

    func stopRecording() {
        guard isRecording else { say("Not recording speech"); return }
        isRecording = false
        guard !recordedItems.isEmpty else { say("Stopped recording. No speech was recorded"); return }
        Self.copyToPasteboard(recordedItems.joined(separator: "\n"))
        say("Recorded speech copied to clipboard")
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
