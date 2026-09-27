import AppKit
import ApplicationServices
import os

/// Unspoken-style control sounds: reports a sound slot whenever keyboard
/// focus lands on a control, a menu item is highlighted, or a row is selected
/// in the frontmost application. Requires the Accessibility permission.
///
/// macOS has no public notification for VoiceOver cursor movement, so this
/// follows keyboard focus; with "keyboard focus follows VoiceOver cursor" on
/// (VoiceOver's default) that covers native controls.
final class FocusMonitor {
    /// Called on the main thread with the slot ("button", "listItem", …) and the element.
    var onFocus: ((String, AXElement) -> Void)?
    var keyboardFocus = true
    var menuItems = true
    var rows = true

    private let log = Logger(subsystem: "com.maccesshub.app", category: "focus")
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedElement: AXUIElement?
    private var activationToken: NSObjectProtocol?
    private var lastSlot: String?
    private var lastTime: TimeInterval = 0

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
            self?.observe(pid: app.processIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication { observe(pid: app.processIdentifier) }
    }

    func stop() {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        detach()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if let observedElement {
                for name in Self.notifications { AXObserverRemoveNotification(observer, observedElement, name as CFString) }
            }
        }
        observer = nil
        observedElement = nil
        observedPID = 0
    }

    private func observe(pid: pid_t) {
        guard pid != observedPID, AccessibilityPermission.isTrusted else { return }
        detach()
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(notification as String, element: AXElement(element))
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications { AXObserverAddNotification(newObserver, element, name as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedElement = element
        observedPID = pid
    }

    private func handle(_ notification: String, element: AXElement) {
        var target = element
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            guard keyboardFocus else { return }
            if target.role == nil, let focused = AXElement.focused { target = focused }
        case kAXMenuItemSelectedNotification:
            guard menuItems else { return }
        case kAXSelectedRowsChangedNotification:
            guard rows else { return }
            // The element is the table; report its first selected row.
            guard let row = target.elements(kAXSelectedRowsAttribute).first else { return }
            target = row
        case kAXSelectedChildrenChangedNotification:
            guard rows, target.role == kAXListRole,
                  let child = target.elements(kAXSelectedChildrenAttribute).first else { return }
            target = child
        default:
            return
        }
        guard let slot = FocusRoleMapper.slot(for: target) else { return }
        // Collapse bursts (a table focusing and selecting its row fires twice).
        let now = ProcessInfo.processInfo.systemUptime
        if slot == lastSlot, now - lastTime < 0.05 { return }
        lastSlot = slot
        lastTime = now
        log.debug("focus \(slot, privacy: .public) (\(target.role ?? "?", privacy: .public)/\(target.subrole ?? "-", privacy: .public))")
        onFocus?(slot, target)
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
