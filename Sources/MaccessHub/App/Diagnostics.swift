import AppKit
import Foundation

enum Diagnostics {
    static func printReports() {
        let speaker = Speaker()
        speaker.sink = { print($0) }
        let audio = AudioSwitchFeature(speaker: speaker)
        let info = SystemInfoFeature(speaker: speaker, audio: audio)
        let library = SoundpackLibrary()

        print("MaccessHub \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        print("Accessibility permission: \(AccessibilityPermission.isTrusted ? "granted" : "not granted")")
        print("VoiceOver running: \(Speaker.isVoiceOverRunning)")
        print("Settings file: \(SettingsStore.fileURL.path)")
        print("Soundpacks: " + library.packs.map { "\($0.name) (\($0.eventCount) sounds)" }.joined(separator: ", "))
        print("")

        print("[CPU]"); let group = DispatchGroup(); group.enter()
        SystemStats.cpuUsage { usage in
            if let usage {
                print(String(format: "CPU %.0f percent. User %.0f percent, system %.0f percent.",
                             usage.overall, usage.user, usage.system))
            } else { print("unavailable") }
            group.leave()
        }
        // cpuUsage completes on the main queue; pump the run loop until it does.
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        print("[Memory]"); info.speakMemory()
        print("[Disks]"); info.speakDisks()
        print("[macOS]"); info.speakOSVersion()
        print("[Uptime]"); info.speakUptime()
        print("[Battery]"); info.speakBattery()
        print("[Audio devices]"); info.speakAudioDevices()
        print("[Output devices]"); audio.list(.output)
        print("[Input devices]"); audio.list(.input)
        print("[Clipboard]"); info.speakClipboard()
        print("[Frontmost app]")
        if let app = NSWorkspace.shared.frontmostApplication { print(AppInfoFeature.describe(app)) }
        print("[Position]")
        if !AccessibilityPermission.isTrusted {
            print("needs Accessibility permission")
        } else if let focused = AXElement.focused {
            print(PositionInfoFeature.describe(focused))
        } else { print("nothing focused") }
        print("[Menu extras]")
        if AccessibilityPermission.isTrusted {
            for (i, extra) in MenuExtrasFeature.visibleExtras().enumerated() { print("\(i + 1): \(extra.label)") }
        } else { print("needs Accessibility permission") }
    }
}
