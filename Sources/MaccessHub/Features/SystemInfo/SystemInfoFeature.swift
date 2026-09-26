import Foundation

/// The recmon spoon: spoken CPU, memory, disk, OS, uptime, battery, audio and clipboard reports.
final class SystemInfoFeature {
    let speaker: Speaker
    let audio: AudioSwitchFeature
    var clipboardReadLimit = 2048
    var browsableVolumesOnly = true

    init(speaker: Speaker, audio: AudioSwitchFeature) {
        self.speaker = speaker
        self.audio = audio
    }

    func speakCPU() {
        SystemStats.cpuUsage { [speaker] usage in
            var message = usage.map {
                String(format: "CPU %.0f percent. User %.0f percent, system %.0f percent.", $0.overall, $0.user, $0.system)
            } ?? "CPU usage is unavailable."
            if let gpu = SystemStats.gpuUsage() { message += " GPU \(gpu) percent." }
            speaker.speak(message)
        }
    }

    func speakMemory() {
        guard let m = SystemStats.memoryUsage() else { speaker.speak("Memory usage is unavailable."); return }
        speaker.speak("Memory: \(SystemStats.bytesToHuman(m.used)) of \(SystemStats.bytesToHuman(m.total)) used, "
                      + "\(m.percentUsed) percent. Apps \(SystemStats.bytesToHuman(m.appMemory)), "
                      + "wired \(SystemStats.bytesToHuman(m.wired)), compressed \(SystemStats.bytesToHuman(m.compressed)).")
    }

    func speakDisks() {
        let volumes = SystemStats.volumes(browsableOnly: browsableVolumesOnly)
        guard !volumes.isEmpty else { speaker.speak("No volumes found."); return }
        let parts = volumes.map {
            "\($0.name) (\($0.format)): \(SystemStats.bytesToHuman($0.used)) of \(SystemStats.bytesToHuman($0.total)) used, \($0.percentUsed) percent."
        }
        speaker.speak(parts.joined(separator: " "))
    }

    func speakOSVersion() { speaker.speak(SystemStats.osVersionDescription()) }

    func speakUptime() { speaker.speak("Up \(SystemStats.uptimeDescription()).") }

    func speakBattery() {
        guard let status = BatteryStatus.current(), status.hasBattery else {
            speaker.speak("This Mac has no battery.")
            return
        }
        var s = "\(status.percentage) percent, "
        switch status.sourceType {
        case "AC Power":
            if status.isCharged {
                s += "fully charged."
            } else if status.isCharging {
                s += "charging. "
                s += status.minutesRemaining.map { "\(SystemStats.minutesDescription($0)) until full." }
                    ?? "Calculating time until full."
            } else {
                s += "on AC power, not charging."
            }
        case "Battery Power":
            s += "on battery. "
            s += status.minutesRemaining.map { "\(SystemStats.minutesDescription($0)) remaining." }
                ?? "Calculating time remaining."
        default:
            s += "on \(status.sourceType)."
        }
        speaker.speak(s)
    }

    func speakAudioDevices() { speaker.speak(audio.describeCurrentDevices()) }

    func speakClipboard() { speaker.speak(SystemStats.clipboardDescription(readLimit: clipboardReadLimit)) }
}
