import AppKit
import ApplicationServices
import os

/// Window, menu and row events from the frontmost application, via an
/// AXObserver that follows app activation. Requires the Accessibility permission.
final class UIEventMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?

    private let log = Logger(subsystem: "com.maccesshub.app", category: "uievents")
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedElement: AXUIElement?
    private var activationToken: NSObjectProtocol?

    private static let notifications: [(String, String)] = [
        (kAXWindowCreatedNotification, "window.created"),
        (kAXFocusedWindowChangedNotification, "window.focused"),
        (kAXWindowMiniaturizedNotification, "window.minimized"),
        (kAXWindowDeminiaturizedNotification, "window.restored"),
        (kAXSheetCreatedNotification, "window.dialogOpened"),
        (kAXMenuOpenedNotification, "ui.menuOpened"),
        (kAXMenuClosedNotification, "ui.menuClosed"),
        (kAXMenuItemSelectedNotification, "ui.menuItemSelected"),
        (kAXRowExpandedNotification, "ui.rowExpanded"),
        (kAXRowCollapsedNotification, "ui.rowCollapsed"),
        (kAXSelectedRowsChangedNotification, "ui.selectedRowChanged"),
    ]
    private static let eventByNotification = Dictionary(uniqueKeysWithValues: notifications)

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
                for (name, _) in Self.notifications {
                    AXObserverRemoveNotification(observer, observedElement, name as CFString)
                }
            }
        }
        observer = nil
        observedElement = nil
        observedPID = 0
    }

    private func observe(pid: pid_t) {
        guard pid != observedPID, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard AccessibilityPermission.isTrusted else { return }
        detach()
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<UIEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if let eventID = UIEventMonitor.eventByNotification[notification as String] {
                monitor.onEvent?(eventID)
            }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else {
            log.debug("Could not observe pid \(pid)")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for (name, _) in Self.notifications {
            AXObserverAddNotification(newObserver, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedElement = element
        observedPID = pid
    }
}
