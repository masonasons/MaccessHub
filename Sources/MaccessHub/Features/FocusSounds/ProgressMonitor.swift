import AppKit
import ApplicationServices
import os

/// Watches progress indicators the way NVDA does: value changes arrive as
/// accessibility notifications, are converted to a percentage, and reported
/// once per whole percent. Bars in the frontmost app are always watched;
/// other apps optionally.
final class ProgressMonitor {
    struct Update {
        let element: AXElement
        let percent: Int
        let inFocusedWindow: Bool
        let inFrontmostApp: Bool
        let frame: CGRect?
    }

    /// Called on the main thread.
    var onUpdate: ((Update) -> Void)?
    var watchBackgroundApps = false { didSet { if running { refreshObservers() } } }

    private let log = Logger(subsystem: "com.maccesshub.app", category: "progress")
    private var observers: [pid_t: (observer: AXObserver, element: AXUIElement)] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var running = false
    private var frontmostPID: pid_t = 0
    /// Last whole percent reported per bar, keyed by a stable-ish identity.
    private var lastPercent: [String: Int] = [:]

    func start() {
        stop()
        running = true
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.frontmostPID = app.processIdentifier
            self?.refreshObservers()
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshObservers()
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(pid: app.processIdentifier)
        })
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        refreshObservers()
    }

    func stop() {
        running = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        for pid in Array(observers.keys) { detach(pid: pid) }
        lastPercent.removeAll()
    }

    private func refreshObservers() {
        guard AccessibilityPermission.isTrusted else { return }
        var wanted: Set<pid_t> = frontmostPID > 0 ? [frontmostPID] : []
        if watchBackgroundApps {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                wanted.insert(app.processIdentifier)
            }
        }
        wanted.remove(ProcessInfo.processInfo.processIdentifier)
        for pid in Array(observers.keys) where !wanted.contains(pid) { detach(pid: pid) }
        for pid in wanted where observers[pid] == nil { attach(pid: pid) }
    }

    private func attach(pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<ProgressMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(AXElement(element))
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let status = AXObserverAddNotification(observer, app, kAXValueChangedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        guard status == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = (observer, app)
    }

    private func detach(pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        AXObserverRemoveNotification(entry.observer, entry.element, kAXValueChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
    }

    private func handle(_ element: AXElement) {
        // Value changes arrive for every control; only progress indicators matter.
        guard element.role == kAXProgressIndicatorRole,
              let value = element.raw(kAXValueAttribute) as? NSNumber else { return }
        let minimum = (element.raw(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
        let maximum = (element.raw(kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 100
        guard maximum > minimum else { return }
        let fraction = (value.doubleValue - minimum) / (maximum - minimum)
        let percent = max(0, min(100, Int((fraction * 100).rounded(.down))))

        let pid = element.pid ?? 0
        let frame = element.frame
        // Identity: process + position is stable for the life of a bar and cheap.
        let key = "\(pid):\(Int(frame?.minX ?? 0)),\(Int(frame?.minY ?? 0))"
        if lastPercent[key] == percent { return }
        lastPercent[key] = percent
        if lastPercent.count > 64 { lastPercent.removeAll() } // bounded, bars come and go

        var inFocusedWindow = false
        if let window = element.element(kAXWindowAttribute),
           let focusedWindow = AXElement.application(pid: pid).element(kAXFocusedWindowAttribute) {
            inFocusedWindow = CFEqual(window.element, focusedWindow.element)
        }
        onUpdate?(Update(element: element, percent: percent, inFocusedWindow: inFocusedWindow,
                         inFrontmostApp: pid == frontmostPID, frame: frame))
    }
}
