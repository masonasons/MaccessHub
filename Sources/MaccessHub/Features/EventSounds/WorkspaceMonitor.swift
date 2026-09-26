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

    func start() {
        stop()
        let wc = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            tokens.append(wc.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
        func emit(_ name: Notification.Name, _ eventID: String) {
            observe(name) { [weak self] _ in self?.onEvent?(eventID) }
        }

        emit(NSWorkspace.willLaunchApplicationNotification, "application.launching")
        emit(NSWorkspace.didLaunchApplicationNotification, "application.launched")
        emit(NSWorkspace.didTerminateApplicationNotification, "application.terminated")
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            // Ignore our own activation (opening settings) to avoid a self-triggered sound.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
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

        let dc = DistributedNotificationCenter.default()
        func distributed(_ name: String, _ handler: @escaping (Notification) -> Void) {
            distributedTokens.append(dc.addObserver(forName: Notification.Name(name), object: nil,
                                                    queue: .main, using: handler))
        }
        distributed("com.apple.screenIsLocked") { [weak self] _ in self?.onEvent?("system.screenLocked") }
        distributed("com.apple.screenIsUnlocked") { [weak self] _ in self?.onEvent?("system.screenUnlocked") }

        // Music.app and Spotify both broadcast their player state.
        let playerHandler: (Notification) -> Void = { [weak self] note in
            guard let state = note.userInfo?["Player State"] as? String else { return }
            switch state {
            case "Playing": self?.onEvent?("media.playing")
            case "Paused": self?.onEvent?("media.paused")
            case "Stopped": self?.onEvent?("media.stopped")
            default: break
            }
        }
        distributed("com.apple.Music.playerInfo", playerHandler)
        distributed("com.apple.iTunes.playerInfo", playerHandler)
        distributed("com.spotify.client.PlaybackStateChanged", playerHandler)
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        tokens.removeAll()
        distributedTokens.removeAll()
    }
}
