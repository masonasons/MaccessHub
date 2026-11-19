import AppKit
import Foundation

/// Application, sleep/wake, session, volume, space, screen-lock and music events,
/// all of which arrive as plain notifications.
final class WorkspaceMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?
    /// Called synchronously so the logout sound has time to play before the session ends.
    var onWillEndSession: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var displayIDs: Set<CGDirectDisplayID> = WorkspaceMonitor.currentDisplayIDs()
    private var lastTrack: String?
    private var lastPlayerState: String?

    /// True for an app a person would think of as an app: an .app bundle that
    /// is not tucked inside a framework. System helpers that put up UI for
    /// someone else (authentication prompts, XPC services, plug-in hosts) are
    /// .bundle or .xpc, or live inside a framework, like SecurityAgent.
    /// When the notification carries no app, it is let through unchanged.
    static func isUserFacingApp(_ note: Notification) -> Bool {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let url = app.bundleURL else { return true }
        return isUserFacingAppPath(url.path)
    }

    static func isUserFacingAppPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "app" else { return false }
        return !path.contains(".framework/")
    }

    private static func currentDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID })
    }

    func start() {
        stop()
        let wc = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            tokens.append(wc.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
        func emit(_ name: Notification.Name, _ eventID: String) {
            observe(name) { [weak self] _ in self?.onEvent?(eventID) }
        }

        // App events only for real apps. A Touch ID or password prompt is drawn
        // by system helpers (coreautha.bundle, LocalAuthenticationRemoteService.xpc)
        // that start and quit with every prompt, and each one used to play
        // "App finished opening" and "App quit", so one prompt sounded twice.
        func emitApp(_ name: Notification.Name, _ eventID: String) {
            observe(name) { [weak self] note in
                guard Self.isUserFacingApp(note) else { return }
                self?.onEvent?(eventID)
            }
        }
        emitApp(NSWorkspace.willLaunchApplicationNotification, "application.launching")
        emitApp(NSWorkspace.didLaunchApplicationNotification, "application.launched")
        emitApp(NSWorkspace.didTerminateApplicationNotification, "application.terminated")
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            // Ignore our own activation (opening settings) to avoid a self-triggered sound.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            guard Self.isUserFacingApp(note) else { return }
            self?.onEvent?("application.activated")
        }

        emit(NSWorkspace.willSleepNotification, "system.willSleep")
        emit(NSWorkspace.didWakeNotification, "system.didWake")
        observe(NSWorkspace.willPowerOffNotification) { [weak self] _ in
            self?.onEvent?("system.logout")
            self?.onWillEndSession?()
        }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.onEvent?("system.logout")
        }
        emit(NSWorkspace.activeSpaceDidChangeNotification, "system.spaceChanged")

        emit(NSWorkspace.didMountNotification, "storage.mounted")
        emit(NSWorkspace.willUnmountNotification, "storage.willUnmount")
        emit(NSWorkspace.didUnmountNotification, "storage.unmounted")
        emit(NSWorkspace.didRenameVolumeNotification, "storage.renamed")

        // Displays: compare the set of screen IDs whenever screen parameters change.
        displayIDs = Self.currentDisplayIDs()
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = Self.currentDisplayIDs()
            if !now.subtracting(displayIDs).isEmpty { onEvent?("display.connected") }
            else if !displayIDs.subtracting(now).isEmpty { onEvent?("display.disconnected") }
            displayIDs = now
        })

        let dc = DistributedNotificationCenter.default()
        func distributed(_ name: String, _ handler: @escaping (Notification) -> Void) {
            distributedTokens.append(dc.addObserver(forName: Notification.Name(name), object: nil,
                                                    queue: .main, using: handler))
        }
        distributed("com.apple.screenIsLocked") { [weak self] _ in self?.onEvent?("system.screenLocked") }
        distributed("com.apple.screenIsUnlocked") { [weak self] _ in self?.onEvent?("system.screenUnlocked") }

        // Music.app and Spotify both broadcast their player state.
        let playerHandler: (Notification) -> Void = { [weak self] note in
            guard let self, let state = note.userInfo?["Player State"] as? String else { return }
            let track = (note.userInfo?["Persistent ID"] as? NSObject)?.description
                ?? (note.userInfo?["Track ID"] as? String)
                ?? (note.userInfo?["Name"] as? String)
            defer { lastPlayerState = state; lastTrack = track ?? lastTrack }
            switch state {
            case "Playing":
                // A new track while already playing is a track change, not a fresh play.
                if lastPlayerState == "Playing", let track, let lastTrack, track != lastTrack {
                    onEvent?("media.trackChanged")
                } else if lastPlayerState != "Playing" {
                    onEvent?("media.playing")
                }
            case "Paused": onEvent?("media.paused")
            case "Stopped": onEvent?("media.stopped")
            default: break
            }
        }
        distributed("com.apple.Music.playerInfo", playerHandler)
        distributed("com.apple.iTunes.playerInfo", playerHandler)
        distributed("com.spotify.client.PlaybackStateChanged", playerHandler)
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        tokens.removeAll()
        distributedTokens.removeAll()
    }
}
