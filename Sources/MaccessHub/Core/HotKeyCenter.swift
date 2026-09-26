import Carbon
import Foundation
import os

/// Registers global shortcuts through Carbon's RegisterEventHotKey, which works
/// without the Accessibility permission and never swallows other keys.
final class HotKeyCenter {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "hotkeys")
    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var nextID: UInt32 = 1
    private var currentBindings: [HotKeyAction: KeyCombo] = [:]
    private var suspended = false

    /// Called on the main thread when a shortcut fires.
    var handler: ((HotKeyAction) -> Void)?

    private static let signature: OSType = {
        // 'MHUB'
        let bytes: [UInt8] = Array("MHUB".utf8)
        return bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            center.fire(id: hotKeyID.id)
            return noErr
        }, 1, &spec, refcon, &handlerRef)
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func fire(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        log.debug("Hotkey fired: \(action.rawValue)")
        handler?(action)
    }

    /// Replaces every registration with the given set.
    func apply(bindings: [HotKeyAction: KeyCombo]) {
        currentBindings = bindings
        guard !suspended else { return }
        unregisterAll()
        for (action, combo) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            register(action: action, combo: combo)
        }
    }

    /// Temporarily releases all shortcuts, e.g. while the user records a new one.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        unregisterAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        apply(bindings: currentBindings)
    }

    private func register(action: HotKeyAction, combo: KeyCombo) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("Could not register \(action.rawValue) (\(combo.displayString)): \(status)")
            return
        }
        registered[id] = (ref, action)
        actionsByID[id] = action
    }

    private func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
        actionsByID.removeAll()
    }
}
