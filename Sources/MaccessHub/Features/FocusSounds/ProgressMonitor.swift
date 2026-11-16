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
    /// Bundle IDs never observed, so their bars cost nothing and make no sound.
    var excludedBundleIDs: Set<String> = [] {
        didSet { if running, excludedBundleIDs != oldValue { refreshObservers() } }
    }

    private let log = Logger(subsystem: "com.maccesshub.app", category: "progress")

    /// One app being watched.
    ///
    /// Listening to value changes on the whole app makes it send us every
    /// value change it has, and in a long list that is several per arrow key
    /// (each row's text, the scroll bar), handled on the main thread
    /// VoiceOver is waiting on. Arrowing through Music's queue got slow
    /// (issue #6). When an app sends a lot of changes that are not progress
    /// bars, we stop listening to the whole app for a while and listen only
    /// to the bars we have already found in it.
    private final class Watch {
        let observer: AXObserver
        let app: AXUIElement
        /// Listening to every value change in the app.
        var appWide = true
        /// Bars seen in this app, newest last.
        var bars: [AXUIElement] = []
        /// Bars listened to one by one while app-wide listening is paused.
        var watchedBars: [AXUIElement] = []
        var countStart: TimeInterval = 0
        var otherChanges = 0
        var pauses = 0
        init(observer: AXObserver, app: AXUIElement) { self.observer = observer; self.app = app }
    }

    private var observers: [pid_t: Watch] = [:]
    /// More changes than this in one second that are not progress bars pauses app-wide listening.
    private static let floodLimit = 20
    /// Pauses grow from 10 seconds to a minute while the app keeps flooding.
    private static let pauseDelays: [TimeInterval] = [10, 20, 40, 60]
    private static let maxBarsPerApp = 8
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
            self?.retries[app.processIdentifier] = nil
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
        retries.removeAll()
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
        if !excludedBundleIDs.isEmpty {
            wanted = wanted.filter { pid in
                guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return true }
                return !excludedBundleIDs.contains(id)
            }
        }
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
        guard status == .success else {
            if status == .cannotComplete { scheduleRetry(pid: pid) }
            return
        }
        retries[pid] = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = Watch(observer: observer, app: app)
    }

    /// Attempts so far per app that answered "cannot complete".
    private var retries: [pid_t: Int] = [:]
    private static let retryDelays: [TimeInterval] = [0.5, 1.5, 4]

    /// An app that has only just launched answers "cannot complete" for a
    /// moment. Without another try its bars went unreported until the user
    /// switched away and back.
    private func scheduleRetry(pid: pid_t) {
        let attempt = retries[pid, default: 0]
        guard attempt < Self.retryDelays.count else { return }
        retries[pid] = attempt + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
            guard let self, running, observers[pid] == nil else { return }
            refreshObservers()
        }
    }

    private func detach(pid: pid_t) {
        guard let watch = observers.removeValue(forKey: pid) else { return }
        if watch.appWide {
            AXObserverRemoveNotification(watch.observer, watch.app, kAXValueChangedNotification as CFString)
        }
        for bar in watch.watchedBars {
            AXObserverRemoveNotification(watch.observer, bar, kAXValueChangedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .defaultMode)
    }

    /// A value change that was not a progress bar. Too many in a second and
    /// the app is flooding us (a list being arrowed through), so pause.
    private func noteOtherChange(pid: pid_t) {
        guard let watch = observers[pid], watch.appWide else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - watch.countStart > 1 {
            watch.countStart = now
            watch.otherChanges = 0
        }
        watch.otherChanges += 1
        if watch.otherChanges > Self.floodLimit { pauseAppWide(pid: pid, watch: watch) }
    }

    private func pauseAppWide(pid: pid_t, watch: Watch) {
        let name = kAXValueChangedNotification as CFString
        AXObserverRemoveNotification(watch.observer, watch.app, name)
        watch.appWide = false
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for bar in watch.bars where AXObserverAddNotification(watch.observer, bar, name, refcon) == .success {
            watch.watchedBars.append(bar)
        }
        let delay = Self.pauseDelays[min(watch.pauses, Self.pauseDelays.count - 1)]
        watch.pauses += 1
        log.debug("pid \(pid, privacy: .public) sent \(watch.otherChanges, privacy: .public) other value changes in a second; watching \(watch.watchedBars.count, privacy: .public) known bars only for \(Int(delay), privacy: .public)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak watch] in
            guard let self, let watch, self.observers[pid] === watch, !watch.appWide else { return }
            self.resumeAppWide(pid: pid, watch: watch)
        }
    }

    /// Listen to the whole app again, so bars that appeared meanwhile are found.
    private func resumeAppWide(pid: pid_t, watch: Watch) {
        let name = kAXValueChangedNotification as CFString
        for bar in watch.watchedBars { AXObserverRemoveNotification(watch.observer, bar, name) }
        watch.watchedBars.removeAll()
        let status = AXObserverAddNotification(watch.observer, watch.app, name, Unmanaged.passUnretained(self).toOpaque())
        watch.appWide = status == .success || status == .notificationAlreadyRegistered
        watch.countStart = ProcessInfo.processInfo.systemUptime
        watch.otherChanges = 0
        if !watch.appWide {
            log.debug("pid \(pid, privacy: .public) refused app-wide value changes again (\(status.rawValue, privacy: .public))")
        }
    }

    private func remember(bar: AXElement, pid: pid_t) {
        guard let watch = observers[pid], !watch.bars.contains(where: { CFEqual($0, bar.element) }) else { return }
        watch.bars.append(bar.element)
        if watch.bars.count > Self.maxBarsPerApp { watch.bars.removeFirst() }
    }

    private func handle(_ element: AXElement) {
        let pid = element.pid ?? 0
        // Value changes arrive for every control; only progress indicators matter.
        guard element.role == kAXProgressIndicatorRole else {
            noteOtherChange(pid: pid)
            return
        }
        remember(bar: element, pid: pid)
        guard let value = element.raw(kAXValueAttribute) as? NSNumber else { return }
        let minimum = (element.raw(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
        let maximum = (element.raw(kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 100
        guard maximum > minimum else { return }
        let fraction = (value.doubleValue - minimum) / (maximum - minimum)
        let percent = max(0, min(100, Int((fraction * 100).rounded(.down))))

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
