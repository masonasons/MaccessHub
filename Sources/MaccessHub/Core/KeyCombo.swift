import AppKit
import Carbon

/// A keyboard shortcut: a virtual key code plus modifier flags.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    /// Subset of NSEvent.ModifierFlags: command, shift, option, control, function.
    var modifiers: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control, .function]).rawValue
    }

    /// Convenience for defaults: `KeyCombo("v", [.control, .shift])`.
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: KeyNames.keyCode(forCharacter: key) ?? 0, modifiers: modifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    /// Symbol form for display: ⌃⇧V
    var displayString: String {
        var parts = ""
        let flags = modifierFlags
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + KeyNames.name(forKeyCode: keyCode)
    }

    /// Word form for VoiceOver: "Control-Shift-V"
    var spokenString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        parts.append(KeyNames.spokenName(forKeyCode: keyCode))
        return parts.joined(separator: "-")
    }
}

/// Key code ↔ name helpers based on the current keyboard layout.
enum KeyNames {
    private static let special: [UInt16: (symbol: String, spoken: String)] = [
        UInt16(kVK_Return): ("↩", "Return"),
        UInt16(kVK_Tab): ("⇥", "Tab"),
        UInt16(kVK_Space): ("Space", "Space"),
        UInt16(kVK_Delete): ("⌫", "Delete"),
        UInt16(kVK_ForwardDelete): ("⌦", "Forward Delete"),
        UInt16(kVK_Escape): ("⎋", "Escape"),
        UInt16(kVK_LeftArrow): ("←", "Left Arrow"),
        UInt16(kVK_RightArrow): ("→", "Right Arrow"),
        UInt16(kVK_UpArrow): ("↑", "Up Arrow"),
        UInt16(kVK_DownArrow): ("↓", "Down Arrow"),
        UInt16(kVK_Home): ("↖", "Home"),
        UInt16(kVK_End): ("↘", "End"),
        UInt16(kVK_PageUp): ("⇞", "Page Up"),
        UInt16(kVK_PageDown): ("⇟", "Page Down"),
        UInt16(kVK_Help): ("Help", "Help"),
        UInt16(kVK_ANSI_KeypadEnter): ("⌤", "Enter"),
        UInt16(kVK_ANSI_KeypadClear): ("⌧", "Clear"),
        UInt16(kVK_F1): ("F1", "F1"), UInt16(kVK_F2): ("F2", "F2"), UInt16(kVK_F3): ("F3", "F3"),
        UInt16(kVK_F4): ("F4", "F4"), UInt16(kVK_F5): ("F5", "F5"), UInt16(kVK_F6): ("F6", "F6"),
        UInt16(kVK_F7): ("F7", "F7"), UInt16(kVK_F8): ("F8", "F8"), UInt16(kVK_F9): ("F9", "F9"),
        UInt16(kVK_F10): ("F10", "F10"), UInt16(kVK_F11): ("F11", "F11"), UInt16(kVK_F12): ("F12", "F12"),
        UInt16(kVK_F13): ("F13", "F13"), UInt16(kVK_F14): ("F14", "F14"), UInt16(kVK_F15): ("F15", "F15"),
        UInt16(kVK_F16): ("F16", "F16"), UInt16(kVK_F17): ("F17", "F17"), UInt16(kVK_F18): ("F18", "F18"),
        UInt16(kVK_F19): ("F19", "F19"), UInt16(kVK_F20): ("F20", "F20"),
    ]

    private static let spokenPunctuation: [String: String] = [
        "[": "Left Bracket", "]": "Right Bracket", ";": "Semicolon", "'": "Quote", ",": "Comma",
        ".": "Period", "/": "Slash", "\\": "Backslash", "-": "Minus", "=": "Equals", "`": "Grave",
    ]

    static func name(forKeyCode code: UInt16) -> String {
        if let s = special[code] { return s.symbol }
        return character(forKeyCode: code)?.uppercased() ?? "Key \(code)"
    }

    static func spokenName(forKeyCode code: UInt16) -> String {
        if let s = special[code] { return s.spoken }
        guard let ch = character(forKeyCode: code) else { return "Key \(code)" }
        return spokenPunctuation[ch] ?? ch.uppercased()
    }

    /// The unshifted character the key produces in the current ASCII-capable layout.
    static func character(forKeyCode code: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        return string.isEmpty ? nil : string
    }

    /// Reverse lookup for defaults (letters, digits, punctuation on the current layout).
    static func keyCode(forCharacter char: String) -> UInt16? {
        let target = char.lowercased()
        for code in UInt16(0)...UInt16(127) where special[code] == nil {
            if character(forKeyCode: code)?.lowercased() == target { return code }
        }
        return nil
    }
}
