import Foundation

/// A category of sounds in a soundpack. Every event belongs to exactly one group.
enum SoundGroup: String, CaseIterable, Identifiable {
    case application, system, power, storage, usb, bluetooth, network, window, ui, media, audio, focus, keys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "Applications"
        case .system: return "System"
        case .power: return "Power & Battery"
        case .storage: return "Disks"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .network: return "Network"
        case .window: return "Windows"
        case .ui: return "Menus & Lists"
        case .media: return "Music"
        case .audio: return "Audio Devices"
        case .focus: return "Focus Sounds"
        case .keys: return "Key Clicks"
        }
    }

    /// Groups that are driven by the event-sounds feature (everything but key clicks and focus).
    static var eventGroups: [SoundGroup] { allCases.filter { $0 != .keys && $0 != .focus } }
}

/// One thing that can make a sound. The `id` doubles as the file name inside a
/// soundpack (`application.launched.wav`), so packs are plain folders of files.
struct SoundEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let group: SoundGroup
    /// Whether the event plays when the user has never touched its toggle.
    let defaultEnabled: Bool
    /// Other event IDs whose sound is used when a pack has no file for this one.
    let fallbacks: [String]
    /// Extra explanation shown in settings.
    let note: String?

    init(_ id: String, _ title: String, _ group: SoundGroup, defaultEnabled: Bool = true,
         fallbacks: [String] = [], note: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultEnabled = defaultEnabled
        self.fallbacks = fallbacks
        self.note = note
    }

    var isKeyClick: Bool { group == .keys }

    static let all: [SoundEvent] = [
        // Applications
        SoundEvent("application.launching", "App starting to open", .application),
        SoundEvent("application.launched", "App finished opening", .application),
        SoundEvent("application.terminated", "App quit", .application),
        SoundEvent("application.activated", "Switched to another app", .application, defaultEnabled: false,
                   note: "Plays every time you switch apps."),

        // System
        SoundEvent("system.login", "MaccessHub started", .system),
        SoundEvent("system.logout", "Log out or shut down", .system),
        SoundEvent("system.willSleep", "Going to sleep", .system),
        SoundEvent("system.didWake", "Woke from sleep", .system),
        SoundEvent("system.screenLocked", "Screen locked", .system, defaultEnabled: false),
        SoundEvent("system.screenUnlocked", "Screen unlocked", .system, defaultEnabled: false),
        SoundEvent("system.spaceChanged", "Switched to another desktop (Space)", .system),
        SoundEvent("display.connected", "Display connected", .system),
        SoundEvent("display.disconnected", "Display disconnected", .system),

        // Power
        SoundEvent("power.acPower", "Switched to the power adapter", .power),
        SoundEvent("power.batteryPower", "Switched to battery power", .power),
        SoundEvent("power.upsPower", "Switched to UPS (backup battery) power", .power),
        SoundEvent("power.charging", "Battery started charging", .power),
        SoundEvent("power.charged", "Battery fully charged", .power),
        SoundEvent("power.battery20Minutes", "20 minutes of battery left", .power),
        SoundEvent("power.battery10Minutes", "10 minutes of battery left", .power),
        SoundEvent("power.battery5Minutes", "5 minutes of battery left", .power),

        // Storage
        SoundEvent("storage.mounted", "Disk connected", .storage),
        SoundEvent("storage.willUnmount", "Disk about to be ejected", .storage),
        SoundEvent("storage.unmounted", "Disk ejected", .storage),
        SoundEvent("storage.renamed", "Disk renamed", .storage),

        // USB
        SoundEvent("usb.connected", "USB device connected", .usb),
        SoundEvent("usb.disconnected", "USB device disconnected", .usb),

        // Bluetooth
        SoundEvent("bluetooth.connected", "Bluetooth device connected", .bluetooth),
        SoundEvent("bluetooth.disconnected", "Bluetooth device disconnected", .bluetooth),

        // Network
        SoundEvent("network.wifiConnected", "Wi-Fi connected", .network),
        SoundEvent("network.wifiDisconnected", "Wi-Fi disconnected", .network),
        SoundEvent("network.ethernetConnected", "Ethernet connected", .network),
        SoundEvent("network.ethernetDisconnected", "Ethernet disconnected", .network),
        SoundEvent("network.ipv4Acquired", "Internet connection available", .network),
        SoundEvent("network.ipv4Released", "Internet connection lost", .network),

        // Windows (accessibility observer on the frontmost app)
        SoundEvent("window.created", "Window opened", .window, defaultEnabled: false),
        SoundEvent("window.focused", "Switched to another window", .window, defaultEnabled: false),
        SoundEvent("window.minimized", "Window minimized", .window, defaultEnabled: false),
        SoundEvent("window.restored", "Window restored from Dock", .window, defaultEnabled: false),
        SoundEvent("window.dialogOpened", "Dialog or sheet opened", .window, defaultEnabled: false),

        // Menus & lists
        SoundEvent("ui.menuOpened", "Menu opened", .ui, defaultEnabled: false),
        SoundEvent("ui.menuClosed", "Menu closed", .ui, defaultEnabled: false),
        SoundEvent("ui.menuItemSelected", "Menu item chosen", .ui, defaultEnabled: false),
        SoundEvent("ui.rowExpanded", "Row expanded", .ui, defaultEnabled: false),
        SoundEvent("ui.rowCollapsed", "Row collapsed", .ui, defaultEnabled: false),
        SoundEvent("ui.selectedRowChanged", "Selected row changed", .ui, defaultEnabled: false,
                   note: "Plays on every arrow key press in lists and tables."),

        // Music
        SoundEvent("media.playing", "Music started playing", .media),
        SoundEvent("media.paused", "Music paused", .media),
        SoundEvent("media.stopped", "Music stopped", .media),
        SoundEvent("media.trackChanged", "Music track changed", .media, defaultEnabled: false),

        // Audio devices (played by the mute shortcut when mute feedback is set to sound)
        SoundEvent("audio.inputMuted", "Microphone muted", .audio,
                   note: "Plays when the mute shortcut is set to play a sound, in Tools."),
        SoundEvent("audio.inputUnmuted", "Microphone unmuted", .audio,
                   note: "Plays when the mute shortcut is set to play a sound, in Tools."),

        // Focus sounds (Unspoken slots), played when focus lands on a control.
        SoundEvent("focus.button", "Button", .focus),
        SoundEvent("focus.checkbox", "Checkbox or switch", .focus),
        SoundEvent("focus.radioButton", "Radio button", .focus),
        SoundEvent("focus.comboBox", "Pop-up menu or combo box", .focus),
        SoundEvent("focus.splitButton", "Menu button", .focus),
        SoundEvent("focus.editableText", "Text field or text area", .focus),
        SoundEvent("focus.link", "Link", .focus),
        SoundEvent("focus.listItem", "List or table row", .focus),
        SoundEvent("focus.treeItem", "Outline row", .focus),
        SoundEvent("focus.menuItem", "Menu item", .focus),
        SoundEvent("focus.tab", "Tab", .focus),
        SoundEvent("focus.slider", "Slider or stepper", .focus),
        SoundEvent("focus.icon", "Image", .focus),
        SoundEvent("focus.clock", "Progress or level indicator", .focus),

        // Key clicks. Fallbacks let a six-sound pack (like Classic) cover every category.
        SoundEvent("key.lower", "Lowercase letter", .keys),
        SoundEvent("key.upper", "Uppercase letter", .keys, fallbacks: ["key.lower"]),
        SoundEvent("key.digit", "Number", .keys, fallbacks: ["key.other"]),
        SoundEvent("key.punctuation", "Punctuation or symbol", .keys, fallbacks: ["key.other"]),
        SoundEvent("key.space", "Space", .keys),
        SoundEvent("key.enter", "Return", .keys),
        SoundEvent("key.tab", "Tab", .keys, fallbacks: ["key.other"]),
        SoundEvent("key.delete", "Delete", .keys),
        SoundEvent("key.navigation", "Arrow and paging keys", .keys, defaultEnabled: false),
        SoundEvent("key.function", "Escape and function keys", .keys, defaultEnabled: false),
        SoundEvent("key.other", "Other keys", .keys),
    ]

    static let byID: [String: SoundEvent] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Events whose sound can stand in when a pack has nothing for this one,
    /// best first. Used only when "Fill gaps with this pack's similar sounds"
    /// is on, and only with files the same pack really has: a related event
    /// that is itself empty is skipped, never followed further, so one sound
    /// can't spread across events it doesn't fit. Every entry stays inside its
    /// own kind of pack (system events, key clicks or focus sounds).
    static let related: [String: [String]] = [
        "application.launching": ["application.launched", "window.created"],
        "application.launched": ["application.launching", "window.created", "window.restored"],
        "application.terminated": ["window.minimized", "media.stopped"],
        "application.activated": ["window.focused", "window.restored", "system.spaceChanged"],
        "system.login": ["system.didWake", "system.screenUnlocked"],
        "system.logout": ["system.willSleep", "system.screenLocked"],
        "system.willSleep": ["system.logout", "system.screenLocked"],
        "system.didWake": ["system.login", "system.screenUnlocked"],
        "system.screenLocked": ["system.willSleep", "system.logout"],
        "system.screenUnlocked": ["system.didWake", "system.login"],
        "system.spaceChanged": ["window.focused", "application.activated", "ui.selectedRowChanged"],
        "display.connected": ["usb.connected", "storage.mounted", "bluetooth.connected"],
        "display.disconnected": ["usb.disconnected", "storage.unmounted", "bluetooth.disconnected"],
        "power.acPower": ["power.charging", "usb.connected"],
        "power.batteryPower": ["power.upsPower", "usb.disconnected"],
        "power.upsPower": ["power.batteryPower"],
        "power.charging": ["power.acPower"],
        "power.charged": ["power.charging", "power.acPower"],
        "power.battery20Minutes": ["power.battery10Minutes", "power.battery5Minutes"],
        "power.battery10Minutes": ["power.battery20Minutes", "power.battery5Minutes"],
        "power.battery5Minutes": ["power.battery10Minutes", "power.battery20Minutes"],
        "storage.mounted": ["usb.connected", "display.connected"],
        "storage.willUnmount": ["storage.unmounted", "usb.disconnected"],
        "storage.unmounted": ["usb.disconnected", "display.disconnected"],
        "storage.renamed": ["ui.menuItemSelected"],
        "usb.connected": ["storage.mounted", "bluetooth.connected", "display.connected"],
        "usb.disconnected": ["storage.unmounted", "bluetooth.disconnected", "display.disconnected"],
        "bluetooth.connected": ["usb.connected", "storage.mounted", "display.connected"],
        "bluetooth.disconnected": ["usb.disconnected", "storage.unmounted", "display.disconnected"],
        "network.wifiConnected": ["network.ethernetConnected", "network.ipv4Acquired"],
        "network.wifiDisconnected": ["network.ethernetDisconnected", "network.ipv4Released"],
        "network.ethernetConnected": ["network.wifiConnected", "network.ipv4Acquired"],
        "network.ethernetDisconnected": ["network.wifiDisconnected", "network.ipv4Released"],
        "network.ipv4Acquired": ["network.wifiConnected", "network.ethernetConnected"],
        "network.ipv4Released": ["network.wifiDisconnected", "network.ethernetDisconnected"],
        "window.created": ["window.restored", "application.launched"],
        "window.focused": ["application.activated", "window.restored", "system.spaceChanged"],
        "window.minimized": ["application.terminated", "media.paused"],
        "window.restored": ["window.created", "media.playing"],
        "window.dialogOpened": ["ui.menuOpened", "window.created"],
        "ui.menuOpened": ["ui.rowExpanded"],
        "ui.menuClosed": ["ui.rowCollapsed", "window.minimized"],
        "ui.menuItemSelected": ["ui.selectedRowChanged", "system.spaceChanged"],
        "ui.rowExpanded": ["ui.menuOpened", "window.restored"],
        "ui.rowCollapsed": ["ui.menuClosed", "window.minimized"],
        "ui.selectedRowChanged": ["system.spaceChanged", "ui.menuItemSelected"],
        "media.playing": ["window.restored", "audio.inputUnmuted"],
        "media.paused": ["window.minimized", "audio.inputMuted"],
        "media.stopped": ["media.paused", "application.terminated"],
        "media.trackChanged": ["ui.selectedRowChanged", "system.spaceChanged", "ui.menuItemSelected"],
        "audio.inputUnmuted": ["media.playing", "window.restored"],
        "audio.inputMuted": ["media.paused", "window.minimized"],

        "focus.treeItem": ["focus.listItem"],
        "focus.listItem": ["focus.treeItem"],
        "focus.menuItem": ["focus.listItem"],
        "focus.splitButton": ["focus.comboBox", "focus.button"],
        "focus.comboBox": ["focus.splitButton", "focus.button"],
        "focus.radioButton": ["focus.checkbox"],
        "focus.checkbox": ["focus.radioButton"],
        "focus.tab": ["focus.button"],
        "focus.link": ["focus.button"],
        "focus.slider": ["focus.clock"],
        "focus.clock": ["focus.slider"],

        "key.lower": ["key.other"],
        "key.other": ["key.lower"],
        "key.navigation": ["key.other", "key.lower"],
        "key.function": ["key.other", "key.lower"],
        "key.space": ["key.other", "key.lower"],
        "key.enter": ["key.other", "key.lower"],
        "key.delete": ["key.other", "key.lower"],
    ]

    /// The first related event `has` says the pack has a sound for.
    static func relatedStandIn(for id: String, has: (String) -> Bool) -> String? {
        related[id]?.first(where: has)
    }

    static func events(in group: SoundGroup) -> [SoundEvent] { all.filter { $0.group == group } }
}
