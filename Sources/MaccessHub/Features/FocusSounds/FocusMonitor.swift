import AppKit
import ApplicationServices
import os

/// Unspoken-style control sounds: reports a sound slot whenever keyboard
/// focus lands on a control, a menu item is highlighted, or a row is selected.
/// Requires the Accessibility permission.
///
/// Three sources feed it, because no single one covers every app:
/// 1. AXObserver notifications from the frontmost app (instant).
/// 2. The same notifications from any other process that owns the focused
///    element, such as the out-of-process open/save panel service.
/// 3. A poll of the system-wide focused element, for apps whose accessibility
///    server refuses observers (Catalyst apps such as Messages) or posts
///    nothing. Anything already reported by a notification is skipped.
///
/// macOS has no public notification for VoiceOver cursor movement, so this
/// follows keyboard focus; with "keyboard focus follows VoiceOver cursor" on
/// (VoiceOver's default) that covers native controls.
final class FocusMonitor {
    /// Called on the main thread with the slot ("button", "listItem", …), the
    /// element, and the rectangle to place the sound at when known.
    var onFocus: ((String, AXElement, CGRect?) -> Void)?
    var keyboardFocus = true
    /// Poll VoiceOver's cursor and hit-test the item under it (covers items
    /// that never take keyboard focus, such as messages and web text).
    var followVoiceOverCursor = false {
        didSet { if pollTimer != nil { followVoiceOverCursor ? voTracker.start() : voTracker.stop() } }
    }
    var menuItems = true
    var rows = true
    /// Seconds between polls of the focused element; 0 disables polling.
    var pollInterval: TimeInterval = 0.1

    private let log = Logger(subsystem: "com.maccesshub.app", category: "focus")

    private final class Observation {
        let pid: pid_t
        let observer: AXObserver
        let element: AXUIElement
        var subscribed = false
        var attempts = 0
        init(pid: pid_t, observer: AXObserver, element: AXUIElement) {
            self.pid = pid; self.observer = observer; self.element = element
        }
    }

    private var observations: [pid_t: Observation] = [:]
    private var primaryPID: pid_t = 0
    private var activationToken: NSObjectProtocol?
    private var pollTimer: Timer?
    private let voTracker = VoiceOverCursorTracker()
    /// Keyboard-focus path (notifications + poll): the last focused element we saw.
    private var lastFocusElement: AXUIElement?
    private var lastFocusSignature: FocusSignature?
    /// VoiceOver-cursor path: the last item under the cursor.
    private var lastCursorSignature: FocusSignature?
    private var lastReport: (signature: FocusSignature, time: TimeInterval)?
    private var lastSlot: String?
    private var lastTime: TimeInterval = 0
    private let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Never let a stalled app block the main thread on a poll.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    private static let notifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXMenuItemSelectedNotification,
        kAXSelectedRowsChangedNotification,
        kAXSelectedChildrenChangedNotification,
    ]

    func start() {
        stop()
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.setPrimary(pid: app.processIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication { setPrimary(pid: app.processIdentifier) }
        if pollInterval > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
            pollTimer?.tolerance = pollInterval / 4
        }
        voTracker.onChange = { [weak self] rect in self?.handleVoiceOverCursor(rect) }
        if followVoiceOverCursor { voTracker.start() }
    }

    func stop() {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        pollTimer?.invalidate()
        pollTimer = nil
        voTracker.stop()
        for pid in Array(observations.keys) { detach(pid: pid) }
        primaryPID = 0
        lastFocusElement = nil
        lastFocusSignature = nil
        lastCursorSignature = nil
    }

    // MARK: Observers

    private func setPrimary(pid: pid_t) {
        log.debug("activated pid \(pid, privacy: .public) (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?", privacy: .public))")
        guard AccessibilityPermission.isTrusted else { return }
        // Drop secondary observers from the previous app; keep the new primary if it exists.
        for other in Array(observations.keys) where other != pid { detach(pid: other) }
        primaryPID = pid
        if let existing = observations[pid], existing.subscribed { return }
        attach(pid: pid)
    }

    private func attach(pid: pid_t) {
        if observations[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(notification as String, element: AXElement(element))
            }
            let status = AXObserverCreate(pid, callback, &observer)
            guard status == .success, let observer else {
                log.debug("AXObserverCreate for pid \(pid, privacy: .public) failed: \(status.rawValue, privacy: .public)")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observations[pid] = Observation(pid: pid, observer: observer, element: AXUIElementCreateApplication(pid))
        }
        subscribe(observations[pid]!)
    }

    private func subscribe(_ observation: Observation) {
        observation.attempts += 1
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var failed = false
        for name in Self.notifications {
            let status = AXObserverAddNotification(observation.observer, observation.element, name as CFString, refcon)
            if status != .success && status != .notificationAlreadyRegistered { failed = true }
        }
        observation.subscribed = !failed
        let name = NSRunningApplication(processIdentifier: observation.pid)?.localizedName ?? "?"
        if failed {
            // Catalyst apps and freshly launched apps answer "cannot complete" for a
            // while; try again a few times before leaving it to the poll.
            let delays: [TimeInterval] = [0.5, 1.5, 4]
            if observation.attempts <= delays.count {
                let delay = delays[observation.attempts - 1]
                log.debug("subscribe pid \(observation.pid, privacy: .public) (\(name, privacy: .public)) failed; retry in \(delay, privacy: .public)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak observation] in
                    guard let self, let observation, self.observations[observation.pid] === observation, !observation.subscribed else { return }
                    self.subscribe(observation)
                }
            } else {
                log.debug("pid \(observation.pid, privacy: .public) (\(name, privacy: .public)) refuses AX notifications; polling only")
            }
        } else {
            log.debug("observing pid \(observation.pid, privacy: .public) (\(name, privacy: .public))")
        }
    }

    private func detach(pid: pid_t) {
        guard let observation = observations.removeValue(forKey: pid) else { return }
        for name in Self.notifications {
            AXObserverRemoveNotification(observation.observer, observation.element, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .defaultMode)
    }

    /// Focus moved into another process (a view service hosting a panel); watch it too.
    private func attachSecondaryIfNeeded(pid: pid_t) {
        guard pid > 0, pid != primaryPID, observations[pid] == nil,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        attach(pid: pid)
    }

    // MARK: Events

    private func handle(_ notification: String, element: AXElement) {
        var target = element
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            guard keyboardFocus else { return }
            // Elements owned by another process come through without a role;
            // the system-wide focused element is the real thing.
            if target.role == nil, let focused = AXElement.focused { target = focused }
            if let pid = target.pid { attachSecondaryIfNeeded(pid: pid) }
        case kAXMenuItemSelectedNotification:
            guard menuItems else { return }
        case kAXSelectedRowsChangedNotification:
            guard rows, let row = target.elements(kAXSelectedRowsAttribute).first else { return }
            target = row
        case kAXSelectedChildrenChangedNotification:
            guard rows, target.role == kAXListRole,
                  let child = target.elements(kAXSelectedChildrenAttribute).first else { return }
            target = child
        default:
            return
        }
        if notification == kAXFocusedUIElementChangedNotification {
            lastFocusElement = target.element
            lastFocusSignature = FocusSignature(target)
        }
        report(target, source: "ax")
    }

    private func poll() {
        guard keyboardFocus else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let element = value as! AXUIElement
        if let last = lastFocusElement, CFEqual(last, element) { return }
        let focused = AXElement(element)
        // Catalyst apps hand out a new token for the same control on every
        // query, so compare what the element is rather than which object it is.
        let signature = FocusSignature(focused)
        lastFocusElement = element
        if signature == lastFocusSignature { return }
        lastFocusSignature = signature
        log.debug("poll: keyboard focus moved to \(focused.role ?? "nil", privacy: .public)/\(focused.subrole ?? "-", privacy: .public) pid=\(focused.pid ?? 0, privacy: .public)")
        if let pid = focused.pid { attachSecondaryIfNeeded(pid: pid) }
        report(focused, source: "poll")
    }

    /// The VoiceOver cursor moved: find the item under it.
    private func handleVoiceOverCursor(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        var value: AXUIElement?
        var status = AXUIElementCopyElementAtPosition(systemWide, Float(rect.midX), Float(rect.midY), &value)
        if status != .success || value == nil, primaryPID != 0 {
            // Some apps (Catalyst) only answer hit-tests addressed to the app itself.
            status = AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(primaryPID),
                                                      Float(rect.midX), Float(rect.midY), &value)
        }
        guard status == .success, let value else { return }
        let hit = AXElement(value)
        // The hit lands on the innermost item. VoiceOver's cursor rectangle is
        // the frame of the item it is on, so prefer the ancestor that matches it.
        var element = hit
        var probe: AXElement? = hit
        var hops = 0
        while let e = probe, hops < 6 {
            if let f = e.frame, Self.matches(f, rect) { element = e; break }
            probe = e.element(kAXParentAttribute)
            hops += 1
        }
        guard let slot = FocusRoleMapper.cursorSlot(for: element) else {
            log.debug("vo cursor: no slot for \(element.role ?? "nil", privacy: .public)/\(element.string(kAXRoleDescriptionAttribute) ?? "-", privacy: .public)")
            return
        }
        let signature = FocusSignature(element)
        if signature == lastCursorSignature { return }
        lastCursorSignature = signature
        if let pid = element.pid { attachSecondaryIfNeeded(pid: pid) }
        report(element, source: "vo", frame: rect, slot: slot)
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }

    private func report(_ target: AXElement, source: String, frame: CGRect? = nil, slot known: String? = nil) {
        guard let slot = known ?? FocusRoleMapper.slot(for: target) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The same control reported by two sources in quick succession (a focus
        // notification, then the VoiceOver cursor landing on it) sounds once.
        let signature = FocusSignature(target)
        if let last = lastReport, last.signature == signature, now - last.time < 0.4 { return }
        lastReport = (signature, now)
        // Collapse bursts (a table focusing and selecting its row fires twice).
        if slot == lastSlot, now - lastTime < 0.05 { return }
        lastSlot = slot
        lastTime = now
        log.debug("focus \(slot, privacy: .public) via \(source, privacy: .public) (\(target.role ?? "?", privacy: .public)/\(target.subrole ?? "-", privacy: .public))")
        onFocus?(slot, target, frame)
    }
}

/// What a focused element *is*, for telling "focus moved" from "same control, new token".
struct FocusSignature: Equatable {
    let pid: pid_t
    let role: String
    let subrole: String
    let identifier: String
    let frame: CGRect

    init(_ element: AXElement) {
        pid = element.pid ?? 0
        role = element.role ?? ""
        subrole = element.subrole ?? ""
        identifier = element.string(kAXIdentifierAttribute) ?? ""
        frame = (element.frame ?? .zero).integral
    }
}

/// Maps macOS accessibility roles onto Unspoken's fourteen sound slots.
enum FocusRoleMapper {
    static func slot(for element: AXElement) -> String? {
        guard let role = element.role else { return nil }
        let subrole = element.subrole
        switch role {
        case kAXButtonRole:
            switch subrole {
            case "AXToggle", "AXSwitch": return "checkbox"
            case "AXTabButton": return "tab"
            default: return "button"
            }
        case kAXCheckBoxRole:
            return "checkbox"
        case kAXRadioButtonRole:
            return subrole == "AXTabButton" ? "tab" : "radioButton"
        case kAXPopUpButtonRole, kAXComboBoxRole:
            return "comboBox"
        case kAXMenuButtonRole:
            return "splitButton"
        case kAXTextFieldRole, kAXTextAreaRole, "AXSearchField", "AXSecureTextField",
             kAXDateFieldRole, kAXTimeFieldRole, kAXColorWellRole:
            return "editableText"
        case kAXStaticTextRole:
            // Static text only counts when it is itself focusable (web content, labels in lists).
            return element.bool(kAXFocusedAttribute) == true ? "editableText" : nil
        case "AXLink":
            return "link"
        case kAXMenuItemRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuBarRole:
            return "menuItem"
        case kAXImageRole:
            return "icon"
        case kAXSliderRole, kAXIncrementorRole, kAXValueIndicatorRole:
            return "slider"
        case kAXProgressIndicatorRole, kAXBusyIndicatorRole, kAXLevelIndicatorRole:
            return "clock"
        case kAXRowRole:
            return isInOutline(element) ? "treeItem" : "listItem"
        case kAXCellRole:
            return "listItem"
        case kAXDisclosureTriangleRole:
            return "checkbox"
        default:
            // Some apps focus a group that stands in for a row or link.
            if subrole == "AXTabButton" { return "tab" }
            if let dom = element.string("AXDOMClassList"), dom.contains("button") { return "button" }
            return nil
        }
    }

    /// Slot for the item under the VoiceOver cursor. Falls back to the role
    /// description (Catalyst apps expose "button", "cell" and so on there), and
    /// treats a child of a collection, list, table or outline as a row.
    static func cursorSlot(for element: AXElement) -> String? {
        if let slot = slot(for: element) { return slot }
        if let slot = slotForRoleDescription(element.string(kAXRoleDescriptionAttribute)) { return slot }
        if let parent = element.element(kAXParentAttribute) {
            let parentRole = parent.role ?? ""
            let parentDescription = (parent.string(kAXRoleDescriptionAttribute) ?? "").lowercased()
            if parentRole == kAXOutlineRole || parentDescription.contains("outline") { return "treeItem" }
            if parentRole == kAXListRole || parentRole == kAXTableRole
                || ["collection", "list", "table", "grid"].contains(where: parentDescription.contains) {
                return "listItem"
            }
        }
        return nil
    }

    private static func slotForRoleDescription(_ description: String?) -> String? {
        guard let d = description?.lowercased(), !d.isEmpty else { return nil }
        let table: [(String, String)] = [
            ("radio button", "radioButton"), ("check box", "checkbox"), ("checkbox", "checkbox"),
            ("switch", "checkbox"), ("toggle", "checkbox"), ("pop up button", "comboBox"), ("popup button", "comboBox"),
            ("combo box", "comboBox"), ("menu button", "splitButton"), ("menu item", "menuItem"), ("menu bar item", "menuItem"),
            ("text field", "editableText"), ("text area", "editableText"), ("search field", "editableText"),
            ("secure text field", "editableText"), ("link", "link"), ("tab", "tab"), ("slider", "slider"),
            ("stepper", "slider"), ("incrementor", "slider"), ("image", "icon"), ("progress indicator", "clock"),
            ("busy indicator", "clock"), ("level indicator", "clock"), ("cell", "listItem"), ("row", "listItem"),
            ("list item", "listItem"), ("button", "button"),
        ]
        for (needle, slot) in table where d.contains(needle) { return slot }
        return nil
    }

    private static func isInOutline(_ element: AXElement) -> Bool {
        var current = element.element(kAXParentAttribute)
        var depth = 0
        while let node = current, depth < 4 {
            if node.role == kAXOutlineRole { return true }
            if node.role == kAXTableRole || node.role == kAXListRole { return false }
            current = node.element(kAXParentAttribute)
            depth += 1
        }
        return false
    }
}
