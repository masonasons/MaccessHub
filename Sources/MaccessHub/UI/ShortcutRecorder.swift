import AppKit
import Carbon
import SwiftUI

/// A button-like control that records a keyboard shortcut. Fully keyboard and
/// VoiceOver operable: activate it, press the new keys, Escape cancels,
/// Delete clears the binding.
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo? { didSet { needsDisplay = true } }
    var label = ""
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            onRecordingChange?(isRecording)
            let message = isRecording
                ? "Recording. Press the new shortcut, Escape to cancel, or Delete to remove it."
                : "Shortcut \(combo?.spokenString ?? "not set")"
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Virtual key codes for F1–F20. They are not contiguous, so no range here.
    private static let functionKeyCodes: Set<UInt16> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map { UInt16($0) })

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press to record a new shortcut. While recording, press Escape to cancel or Delete to remove the shortcut.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? {
        isRecording ? "Recording" : (combo?.spokenString ?? "Not set")
    }
    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        toggleRecording()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        toggleRecording()
    }

    private func toggleRecording() { isRecording.toggle() }

    override func resignFirstResponder() -> Bool {
        if isRecording { isRecording = false }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                isRecording = true
            } else {
                super.keyDown(with: event)
            }
            return
        }
        let code = event.keyCode
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
        if code == UInt16(kVK_Escape) {
            isRecording = false
            return
        }
        if (code == UInt16(kVK_Delete) || code == UInt16(kVK_ForwardDelete)) && flags.isEmpty {
            combo = nil
            onChange?(nil)
            isRecording = false
            return
        }
        // Function keys may stand alone; everything else needs a real modifier.
        let isFunctionKey = Self.functionKeyCodes.contains(code)
        let hasModifier = !flags.intersection([.command, .option, .control]).isEmpty
        guard isFunctionKey || hasModifier else {
            NSSound.beep()
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "Include Command, Option or Control.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        let new = KeyCombo(keyCode: code, modifiers: flags)
        combo = new
        onChange?(new)
        isRecording = false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Capture Command-combos before the menu bar sees them while recording.
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let text = isRecording ? "Type shortcut…" : (combo?.displayString ?? "None")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: combo == nil && !isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(frame: .zero)
        view.label = label
        view.combo = combo
        view.onChange = { combo = $0 }
        view.onRecordingChange = { recording in
            Task { @MainActor in AppController.shared.isRecordingShortcut = recording }
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.label = label
        if view.combo != combo { view.combo = combo }
    }
}
