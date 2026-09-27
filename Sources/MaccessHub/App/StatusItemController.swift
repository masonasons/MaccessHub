import AppKit

/// The menu bar item. Built with AppKit so VoiceOver gets a plain NSMenu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let eventSoundsItem = NSMenuItem(title: "Event Sounds", action: #selector(toggleEventSounds), keyEquivalent: "")
    private let keyClicksItem = NSMenuItem(title: "Key Clicks", action: #selector(toggleKeyClicks), keyEquivalent: "")
    private let focusSoundsItem = NSMenuItem(title: "Focus Sounds", action: #selector(toggleFocusSounds), keyEquivalent: "")

    override init() {
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "MaccessHub")
            button.setAccessibilityLabel("MaccessHub")
            button.toolTip = "MaccessHub"
        }
        eventSoundsItem.target = self
        keyClicksItem.target = self
        focusSoundsItem.target = self
        menu.delegate = self
        menu.addItem(eventSoundsItem)
        menu.addItem(keyClicksItem)
        menu.addItem(focusSoundsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Speak Menu Extras", action: #selector(speakMenuExtras), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(withTitle: "Open Soundpacks Folder", action: #selector(openSoundpacksFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MaccessHub", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let data = AppController.shared.settings.data
        eventSoundsItem.state = data.eventSounds.enabled ? .on : .off
        keyClicksItem.state = data.keyClicks.enabled ? .on : .off
        focusSoundsItem.state = data.focusSounds.enabled ? .on : .off
    }

    @objc private func toggleEventSounds() { AppController.shared.settings.data.eventSounds.enabled.toggle() }
    @objc private func toggleKeyClicks() { AppController.shared.settings.data.keyClicks.enabled.toggle() }
    @objc private func toggleFocusSounds() { AppController.shared.settings.data.focusSounds.enabled.toggle() }
    @objc private func speakMenuExtras() { AppController.shared.menuExtras.speakAll() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openSoundpacksFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SoundpackLibrary.userPacksDirectory])
    }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
