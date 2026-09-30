import AppKit
import Foundation
import os
import ServiceManagement

/// Central object: owns the settings, sound engine, speaker, hotkeys and every feature,
/// and re-applies configuration whenever settings change.
@MainActor
final class AppController {
    static let shared = AppController()

    let log = Logger(subsystem: "com.maccesshub.app", category: "app")
    let settings = SettingsStore()
    let library = SoundpackLibrary()
    let engine = SoundEngine()
    let speaker = Speaker()
    let hotkeys = HotKeyCenter()

    let audioSwitch: AudioSwitchFeature
    let systemInfo: SystemInfoFeature
    let appInfo: AppInfoFeature
    let positionInfo: PositionInfoFeature
    let menuExtras: MenuExtrasFeature
    let keyClicks = KeyClickMonitor()
    let focusMonitor = FocusMonitor()
    private var focusMonitorRunning = false

    private let workspaceMonitor = WorkspaceMonitor()
    private let eventMonitors: [EventMonitor]
    private var monitorsRunning = false

    private var doublePressInterval = 0.35
    private var pendingPress: (action: HotKeyAction, work: DispatchWorkItem)?

    private var healthTimer: Timer?
    private var wasTrusted = AccessibilityPermission.isTrusted

    /// Set by the settings UI while a shortcut is being recorded.
    var isRecordingShortcut = false {
        didSet { isRecordingShortcut ? hotkeys.suspend() : hotkeys.resume() }
    }

    var scheme: SoundScheme { SoundScheme(settings: settings.data, library: library) }

    private init() {
        audioSwitch = AudioSwitchFeature(speaker: speaker)
        systemInfo = SystemInfoFeature(speaker: speaker, audio: audioSwitch)
        appInfo = AppInfoFeature(speaker: speaker)
        positionInfo = PositionInfoFeature(speaker: speaker)
        menuExtras = MenuExtrasFeature(speaker: speaker)
        eventMonitors = [workspaceMonitor, PowerMonitor(), NetworkMonitor(), USBMonitor(),
                         BluetoothMonitor(), UIEventMonitor()]

        for monitor in eventMonitors {
            monitor.onEvent = { [weak self] id in self?.handleEvent(id) }
        }
        workspaceMonitor.onWillEndSession = { [weak self] in
            // Give the logout sound a moment before the session is torn down.
            guard let self, let event = SoundEvent.byID["system.logout"],
                  settings.data.eventSounds.enabled, settings.data.isEnabled(event), scheme.url(for: event) != nil
            else { return }
            Thread.sleep(forTimeInterval: 1.5)
        }
        keyClicks.onKey = { [weak self] category in
            DispatchQueue.main.async { self?.handleKey(category) }
        }
        focusMonitor.onFocus = { [weak self] slot, element, frame in self?.handleFocus(slot, element: element, frame: frame) }
        hotkeys.handler = { [weak self] action in self?.perform(action) }
        // Feedback sounds for the mute toggle bypass the event-sounds master switch.
        audioSwitch.playSound = { [weak self] id in
            guard let self, let event = SoundEvent.byID[id], let url = scheme.url(for: event) else { return false }
            engine.play(url, volume: Float(settings.data.eventSounds.volume))
            return true
        }
        settings.onChange = { [weak self] _ in self?.applySettings() }
    }

    // MARK: Lifecycle

    func start() {
        applySettings()
        // Permissions can be granted (or re-granted after an update changes the
        // signing identity) while the app is running. Re-check every few seconds
        // and bring up anything that could not start earlier.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkHealth() }
        healthTimer?.tolerance = 1
        if settings.data.eventSounds.enabled { play("system.login", ignoreEnabledState: false) }
        log.info("MaccessHub started")
    }

    private func checkHealth() {
        let data = settings.data
        let trusted = AccessibilityPermission.isTrusted
        if trusted != wasTrusted {
            log.info("Accessibility permission changed: \(trusted)")
            wasTrusted = trusted
            if trusted {
                // Observers skipped attaching while untrusted; start them over.
                if focusMonitorRunning { focusMonitor.stop(); focusMonitor.start() }
                if monitorsRunning { eventMonitors.forEach { $0.stop(); $0.start() } }
            }
        }
        if data.keyClicks.enabled, !keyClicks.isRunning, trusted {
            if keyClicks.start() { log.info("Key click tap started after permission became available") }
        }
    }

    func applySettings() {
        let data = settings.data

        speaker.output = data.general.speechOutput
        speaker.rate = data.general.speechRate
        speaker.volume = data.general.speechVolume
        speaker.voiceIdentifier = data.general.speechVoice

        audioSwitch.wrapAround = data.audioDevices.wrapAround
        audioSwitch.speakVolume = data.audioDevices.speakVolume
        audioSwitch.muteFeedback = data.audioDevices.muteFeedback
        systemInfo.clipboardReadLimit = data.systemInfo.clipboardReadLimit
        systemInfo.browsableVolumesOnly = data.systemInfo.browsableVolumesOnly
        systemInfo.topProcessCount = data.systemInfo.topProcessCount
        systemInfo.includeGPUProcesses = data.systemInfo.includeGPUProcesses
        doublePressInterval = data.general.doublePressInterval

        keyClicks.scope = data.keyClicks.scope
        keyClicks.playOnRepeat = data.keyClicks.playOnRepeat
        keyClicks.ignoreWithCommand = data.keyClicks.ignoreWithCommand
        keyClicks.ignoreWithControl = data.keyClicks.ignoreWithControl
        keyClicks.ignoreWithOption = data.keyClicks.ignoreWithOption

        if data.keyClicks.enabled {
            if !keyClicks.isRunning, !keyClicks.start() {
                log.error("Key clicks enabled but the event tap could not start")
            }
        } else if keyClicks.isRunning {
            keyClicks.stop()
        }

        if data.eventSounds.enabled, !monitorsRunning {
            eventMonitors.forEach { $0.start() }
            monitorsRunning = true
        } else if !data.eventSounds.enabled, monitorsRunning {
            eventMonitors.forEach { $0.stop() }
            monitorsRunning = false
        }

        focusMonitor.keyboardFocus = data.focusSounds.keyboardFocus
        focusMonitor.menuItems = data.focusSounds.menuItems
        focusMonitor.rows = data.focusSounds.rows
        focusMonitor.followVoiceOverCursor = data.focusSounds.followVoiceOverCursor
        engine.setReverb(data.focusSounds.reverb, amount: data.focusSounds.reverbAmount)
        if data.focusSounds.enabled, !focusMonitorRunning {
            focusMonitor.start()
            focusMonitorRunning = true
        } else if !data.focusSounds.enabled, focusMonitorRunning {
            focusMonitor.stop()
            focusMonitorRunning = false
        }

        hotkeys.apply(bindings: data.activeHotkeys)
        applyLaunchAtLogin(data.general.launchAtLogin)

        // Warm the cache off the main thread so the first sound is instant.
        let urls = scheme.allURLs()
        DispatchQueue.global(qos: .utility).async { [engine] in
            urls.forEach { engine.preload($0) }
            engine.retainOnly(urls)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let isRegistered = service.status == .enabled
        guard enabled != isRegistered else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            log.error("Launch at login change failed: \(error.localizedDescription)")
        }
    }

    // MARK: Sounds

    private func handleEvent(_ id: String) {
        guard settings.data.eventSounds.enabled else { return }
        play(id, ignoreEnabledState: false)
    }

    private func handleFocus(_ slot: String, element: AXElement?, frame: CGRect?) {
        let data = settings.data
        guard data.focusSounds.enabled, let event = SoundEvent.byID["focus.\(slot)"],
              data.focusSounds.isEnabled(event), let url = scheme.url(for: event) else { return }
        if data.focusSounds.spatial {
            let position = (frame ?? element?.frame).map { SpatialMapper.position(for: $0) } ?? SpatialMapper.center
            engine.playSpatial(url, volume: Float(data.focusSounds.volume), at: position)
        } else {
            engine.play(url, volume: Float(data.focusSounds.volume), exclusive: true)
        }
    }

    /// Plays the button sound at the left, centre and right of the desktop so the
    /// user can check that HRTF placement is audible.
    func previewSpatialPositions() {
        guard let event = SoundEvent.byID["focus.button"], let url = scheme.url(for: event) else { return }
        let desktop = SpatialMapper.desktopBounds()
        let volume = Float(settings.data.focusSounds.volume)
        let spots: [(CGFloat, CGFloat)] = [(0.05, 0.9), (0.5, 0.5), (0.95, 0.1)]
        for (i, spot) in spots.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [engine] in
                let frame = CGRect(x: desktop.minX + desktop.width * spot.0, y: desktop.minY + desktop.height * spot.1,
                                   width: 1, height: 1)
                engine.playSpatial(url, volume: volume, at: SpatialMapper.position(for: frame, in: desktop), exclusive: false)
            }
        }
    }

    private func handleKey(_ category: KeyCategory) {
        let data = settings.data
        guard data.keyClicks.enabled, let event = SoundEvent.byID[category.eventID],
              data.keyClicks.isEnabled(event), let url = scheme.url(for: event) else { return }
        engine.play(url, volume: Float(data.keyClicks.volume), exclusive: true)
    }

    /// Plays the event's sound. `ignoreEnabledState` is used by the preview buttons.
    @discardableResult
    func play(_ id: String, ignoreEnabledState: Bool) -> Bool {
        guard let event = SoundEvent.byID[id] else { return false }
        let data = settings.data
        if !ignoreEnabledState, !data.isEnabled(event) { return false }
        guard let url = scheme.url(for: event) else { return false }
        let volume: Double
        switch event.group {
        case .keys: volume = data.keyClicks.volume
        case .focus: volume = data.focusSounds.volume
        default: volume = data.eventSounds.volume
        }
        engine.play(url, volume: Float(volume), exclusive: event.isKeyClick || event.group == .focus)
        return true
    }

    func preview(_ event: SoundEvent) {
        if !play(event.id, ignoreEnabledState: true) {
            speaker.speak("No sound for \(event.title).")
        }
    }

    // MARK: Hotkeys

    /// Entry point for shortcuts. Actions with a double-press behaviour wait
    /// briefly for a second press; everything else runs immediately.
    func perform(_ action: HotKeyAction) {
        guard action.hasDoublePress else { performSingle(action); return }
        if let pending = pendingPress, pending.action == action {
            pending.work.cancel()
            pendingPress = nil
            performDouble(action)
            return
        }
        pendingPress?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPress = nil
            self?.performSingle(action)
        }
        pendingPress = (action, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + doublePressInterval, execute: work)
    }

    private func performDouble(_ action: HotKeyAction) {
        log.debug("Double press: \(action.rawValue)")
        switch action {
        case .cpuUsage: systemInfo.speakTopCPUProcesses()
        case .memoryUsage: systemInfo.speakTopMemoryProcesses()
        default:
            if let index = action.menuExtraIndex { menuExtras.handle(index: index, action: .activate) }
        }
    }

    private func performSingle(_ action: HotKeyAction) {
        log.debug("Single press: \(action.rawValue)")
        switch action {
        case .previousOutputDevice: audioSwitch.step(.output, by: -1)
        case .nextOutputDevice: audioSwitch.step(.output, by: 1)
        case .previousInputDevice: audioSwitch.step(.input, by: -1)
        case .nextInputDevice: audioSwitch.step(.input, by: 1)
        case .toggleInputMute: audioSwitch.toggleInputMute()
        case .listOutputDevices: audioSwitch.list(.output)
        case .listInputDevices: audioSwitch.list(.input)
        case .cpuUsage: systemInfo.speakCPU()
        case .memoryUsage: systemInfo.speakMemory()
        case .diskUsage: systemInfo.speakDisks()
        case .osVersion: systemInfo.speakOSVersion()
        case .uptime: systemInfo.speakUptime()
        case .battery: systemInfo.speakBattery()
        case .audioDevices: systemInfo.speakAudioDevices()
        case .clipboard: systemInfo.speakClipboard()
        case .deviceBatteries: systemInfo.speakDeviceBatteries()
        case .appInfo: appInfo.speakFrontmostApp()
        case .positionInfo: positionInfo.speakPosition()
        case .toggleEventSounds: toggleEventSounds()
        case .toggleKeyClicks: toggleKeyClicks()
        case .toggleFocusSounds: toggleFocusSounds()
        case .openSettings: SettingsWindowController.shared.show()
        default:
            if let index = action.menuExtraIndex { menuExtras.handle(index: index, action: .speak) }
        }
    }

    func toggleEventSounds() {
        settings.data.eventSounds.enabled.toggle()
        speaker.speak(settings.data.eventSounds.enabled ? "Event sounds on" : "Event sounds off")
    }

    func toggleFocusSounds() {
        settings.data.focusSounds.enabled.toggle()
        speaker.speak(settings.data.focusSounds.enabled ? "Focus sounds on" : "Focus sounds off")
    }

    func toggleKeyClicks() {
        settings.data.keyClicks.enabled.toggle()
        speaker.speak(settings.data.keyClicks.enabled ? "Key clicks on" : "Key clicks off")
    }
}
