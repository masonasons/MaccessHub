import AppKit
import ApplicationServices
import Carbon
import os

/// Which sound a key press maps to.
enum KeyCategory: String {
    case lower, upper, digit, punctuation, space, enter, tab, delete, navigation, function, other
    var eventID: String { "key.\(rawValue)" }
}

/// Listens to key presses system-wide with a passive event tap and classifies
/// them. Requires Accessibility (or Input Monitoring) permission.
final class KeyClickMonitor {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "keyclicks")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let queue = DispatchQueue(label: "com.maccesshub.keyclicks", qos: .userInteractive)

    var scope: KeyClickScope = .textFieldsOnly
    var playOnRepeat = true
    var ignoreWithCommand = true
    var ignoreWithControl = false
    var ignoreWithOption = false

    /// Called on a background queue with the category of each qualifying key press.
    var onKey: ((KeyCategory) -> Void)?

    private(set) var isRunning = false
    private static var requestedListenAccess = false

    /// True if a tap could be created; false usually means permission is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { proxy, type, event, refcon in
                                              guard let refcon else { return Unmanaged.passUnretained(event) }
                                              let monitor = Unmanaged<KeyClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
                                              monitor.handle(type: type, event: event)
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: refcon) else {
            let preflight = CGPreflightListenEventAccess()
            log.error("Could not create key event tap (Input Monitoring preflight: \(preflight, privacy: .public), Accessibility: \(AXIsProcessTrusted(), privacy: .public))")
            if !preflight, !Self.requestedListenAccess {
                // Tap creation never prompts; this does, and adds the app to the Input Monitoring list.
                Self.requestedListenAccess = true
                let asked = CGRequestListenEventAccess()
                log.info("Requested Input Monitoring access: \(asked, privacy: .public)")
            }
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        log.info("Key event tap created (enabled: \(CGEvent.tapIsEnabled(tap: tap), privacy: .public))")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let flags = event.flags
        if ignoreWithCommand, flags.contains(.maskCommand) { return }
        if ignoreWithControl, flags.contains(.maskControl) { return }
        if ignoreWithOption, flags.contains(.maskAlternate) { return }
        if !playOnRepeat, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let characters = NSEvent(cgEvent: event)?.characters ?? ""
        let category = Self.classify(keyCode: keyCode, characters: characters)
        let scope = self.scope
        queue.async { [weak self] in
            guard let self else { return }
            let inField = Self.isTypingInTextField()
            self.log.debug("key \(category.rawValue, privacy: .public) scope=\(scope.rawValue, privacy: .public) inTextField=\(inField, privacy: .public)")
            if scope == .textFieldsOnly, !inField { return }
            self.onKey?(category)
        }
    }

    static func classify(keyCode: UInt16, characters: String) -> KeyCategory {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Delete, kVK_ForwardDelete: return .delete
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return .navigation
        case kVK_Escape, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
             kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return .function
        default: break
        }
        guard let scalar = characters.unicodeScalars.first else { return .other }
        // Private-use characters are how macOS reports function-style keys.
        if (0xF700...0xF8FF).contains(scalar.value) { return .function }
        let props = scalar.properties
        if props.isWhitespace { return .space }
        if props.numericType != nil { return .digit }
        if props.isAlphabetic {
            if props.isUppercase { return .upper }
            if props.isLowercase { return .lower }
            return .lower // caseless scripts
        }
        switch props.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return .punctuation
        default:
            return .other
        }
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", "AXSecureTextField",
    ]

    static func isTypingInTextField() -> Bool {
        guard let focused = AXElement.focused, let role = focused.role else { return false }
        if textRoles.contains(role) { return true }
        // Editable web content reports a generic role with an editable flag,
        // or a selected text range it lets us read.
        if role == "AXWebArea" || role == kAXGroupRole || role == kAXStaticTextRole {
            if focused.bool("AXEditable") == true { return true }
            if focused.range(kAXSelectedTextRangeAttribute) != nil, focused.int(kAXNumberOfCharactersAttribute) != nil {
                return true
            }
        }
        return false
    }
}
