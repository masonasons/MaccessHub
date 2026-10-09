// Self-check for SpeechHistoryFeature. Run with `make check`.
// Note: exercises copy, so it overwrites the clipboard.
import AppKit

@MainActor func run() {
    var spoken: [String] = []
    let speaker = Speaker()
    speaker.sink = { spoken.append($0) }
    let h = SpeechHistoryFeature(speaker: speaker)

    // Capture, trimming, empty phrases.
    assert(h.capture("  one  "))
    assert(!h.capture("   "))
    assert(h.capture("two")); assert(h.capture("three"))
    assert(h.history.map(\.text) == ["one", "two", "three"])

    // Review moves back, stops at the edge, and resets on new speech.
    h.previous(); assert(spoken.last == "two")
    h.previous(); assert(spoken.last == "one")
    h.previous(); assert(spoken.last == "Oldest: one")
    h.next(); h.next(); assert(spoken.last == "three" && h.selectedIndex == nil)
    h.next(); assert(spoken.last == "Newest: three")
    h.previous(); assert(h.current?.text == "two")

    // Replayed speech echoes back from VoiceOver and must not be stored…
    assert(!h.capture("Newest: three"))
    // …but only once per replay, and not after the window expires.
    h.say("echo")
    assert(!h.capture("echo")); assert(h.capture("echo"))
    h.say("late", at: Date(timeIntervalSinceNow: -10))
    assert(h.capture("late"))
    assert(h.selectedIndex == nil, "new speech resets review to newest")

    // Copy.
    h.copyCurrent()
    assert(NSPasteboard.general.string(forType: .string) == "late")
    assert(!h.capture("Copied"))

    // Bounded storage.
    h.maximumHistoryLength = 3
    assert(h.history.map(\.text) == ["three", "echo", "late"])
    for i in 0..<10 { h.capture("n\(i)") }
    assert(h.history.count == 3 && h.history.last?.text == "n9")

    // Recording.
    h.stopRecording(); assert(spoken.last == "Not recording speech")
    h.startRecording()
    assert(!h.capture("Started recording speech"))
    h.capture("a"); h.capture("b")
    h.stopRecording()
    assert(NSPasteboard.general.string(forType: .string) == "a\nb")
    h.capture("c"); assert(h.recordedItems == ["a", "b"])

    // Pausing and clearing.
    h.isPaused = { true }; assert(!h.capture("x")); h.isPaused = { false }
    h.clear(); assert(h.history.isEmpty && h.current == nil)
    h.previous(); assert(spoken.last == "No speech history")

    print("SpeechHistoryFeature: all checks passed")
}

@main enum SpeechHistoryCheck {
    @MainActor static func main() { run() }
}
