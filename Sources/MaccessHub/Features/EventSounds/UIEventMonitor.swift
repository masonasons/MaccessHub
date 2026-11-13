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
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedElement = element
        observedPID = pid
        subscribe(pid: pid, attempt: 0)
    }

    /// Delays before asking again when the app is not ready yet.
    private static let retryDelays: [TimeInterval] = [0.5, 1.5, 4]

    /// Registers for the notifications. An app that has only just launched
    /// (it activates as it opens) answers "cannot complete" for a moment, and
    /// without another try its windows and menus would make no sound until
    /// the user switched away and back.
    private func subscribe(pid: pid_t, attempt: Int) {
        guard let observer, let observedElement, observedPID == pid else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notReady = false
        for (name, _) in Self.notifications {
            let status = AXObserverAddNotification(observer, observedElement, name as CFString, refcon)
            if status == .cannotComplete { notReady = true }
        }
        guard notReady else { return }
        guard attempt < Self.retryDelays.count else {
            log.debug("pid \(pid) is still not answering; window and menu sounds may be missing for it")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
            self?.subscribe(pid: pid, attempt: attempt + 1)
        }
    }
}
