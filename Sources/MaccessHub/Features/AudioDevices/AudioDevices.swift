import AudioToolbox
import CoreAudio
import Foundation
import os

/// CoreAudio device enumeration and default-device control.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String

    enum Direction {
        case input, output
        var scope: AudioObjectPropertyScope {
            self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        }
        var defaultSelector: AudioObjectPropertySelector {
            self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        }
        var noun: String { self == .input ? "input" : "output" }
    }

    // MARK: Enumeration

    static func all(_ direction: Direction) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        // Only devices the user could pick in System Settings. This drops the
        // private "CADefaultDeviceAggregate" CoreAudio creates for our own audio
        // engine, which otherwise appears in the list and silently refuses to
        // become the default, stalling the cycle before virtual devices.
        return ids.filter { streamCount($0, scope: direction.scope) > 0 && canBeDefault($0, scope: direction.scope) }
            .map { AudioDevice(id: $0, name: name(of: $0)) }
    }

    private static func canBeDefault(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return true }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return true }
        return value != 0
    }

    private static func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else {
            return "Device \(id)"
        }
        return name.takeRetainedValue() as String
    }

    // MARK: Defaults

    static func defaultDevice(_ direction: Direction) -> AudioDevice? {
        var address = AudioObjectPropertyAddress(mSelector: direction.defaultSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return AudioDevice(id: id, name: name(of: id))
    }

    @discardableResult
    func makeDefault(_ direction: Direction) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: direction.defaultSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = self.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr {
            Logger(subsystem: "com.maccesshub.app", category: "audioswitch").error("Set default \(direction.noun) to \(self.id) failed: \(status)")
        }
        return status == noErr
    }

    // MARK: Volume & mute

    /// 0...100, or nil if the device has no main volume control.
    func volumePercent(_ direction: Direction) -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: direction.scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return Int((volume * 100).rounded())
    }

    private func muteAddresses(_ direction: Direction) -> [AudioObjectPropertyAddress] {
        // Prefer the main element; fall back to per-channel mute for devices without one.
        [kAudioObjectPropertyElementMain, 1, 2].map {
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: direction.scope, mElement: $0)
        }
    }

    func isMuted(_ direction: Direction) -> Bool? {
        for var address in muteAddresses(direction) where AudioObjectHasProperty(id, &address) {
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &muted) == noErr { return muted != 0 }
        }
        return nil
    }

    @discardableResult
    func setMuted(_ muted: Bool, _ direction: Direction) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var changed = false
        for var address in muteAddresses(direction) where AudioObjectHasProperty(id, &address) {
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                changed = true
                if address.mElement == kAudioObjectPropertyElementMain { break }
            }
        }
        return changed
    }
}

/// The Audioswitch spoon: cycle and describe devices, toggle the mic.
final class AudioSwitchFeature {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "audioswitch")
    let speaker: Speaker
    var wrapAround = true
    var speakVolume = false

    init(speaker: Speaker) { self.speaker = speaker }

    func step(_ direction: AudioDevice.Direction, by delta: Int) {
        let devices = AudioDevice.all(direction)
        guard !devices.isEmpty else {
            speaker.speak("No \(direction.noun) devices.")
            return
        }
        let current = AudioDevice.defaultDevice(direction)
        let index = devices.firstIndex { $0.id == current?.id } ?? 0
        var target = index + delta
        if wrapAround {
            target = (target + devices.count) % devices.count
        } else if target < 0 || target >= devices.count {
            speaker.speak(delta < 0 ? "Already at the first \(direction.noun) device." : "Already at the last \(direction.noun) device.")
            return
        }
        let device = devices[target]
        log.debug("Switch \(direction.noun): current \(current?.id ?? 0) index \(index) of \(devices.count) -> target \(target) \(device.id) \(device.name)")
        guard device.makeDefault(direction) else {
            log.error("makeDefault failed for \(device.id) \(device.name)")
            speaker.speak("Could not switch to \(device.name).")
            return
        }
        var message = device.name
        if speakVolume, let volume = device.volumePercent(direction) { message += ", \(volume) percent" }
        speaker.speak(message)
    }

    func toggleInputMute() {
        guard let device = AudioDevice.defaultDevice(.input) else {
            speaker.speak("No input device.")
            return
        }
        guard let muted = device.isMuted(.input) else {
            speaker.speak("\(device.name) cannot be muted.")
            return
        }
        if device.setMuted(!muted, .input) {
            speaker.speak(muted ? "Unmuted" : "Muted")
        } else {
            speaker.speak("Could not change mute for \(device.name).")
        }
    }

    func list(_ direction: AudioDevice.Direction) {
        let devices = AudioDevice.all(direction)
        let current = AudioDevice.defaultDevice(direction)
        let names = devices.map { $0.id == current?.id ? "\($0.name) (current)" : $0.name }
        let count = devices.count == 1 ? "1 \(direction.noun) device" : "\(devices.count) \(direction.noun) devices"
        speaker.speak(names.isEmpty ? count : "\(count): \(names.joined(separator: ", "))")
    }

    /// The recmon "audio devices" report: current input and output with levels.
    func describeCurrentDevices() -> String {
        var parts: [String] = []
        if let input = AudioDevice.defaultDevice(.input) {
            var s = "Input: \(input.name)"
            if let v = input.volumePercent(.input) { s += " (volume \(v) percent)" }
            if input.isMuted(.input) == true { s += ", muted" }
            parts.append(s)
        } else {
            parts.append("No input device")
        }
        if let output = AudioDevice.defaultDevice(.output) {
            var s = "Output: \(output.name)"
            if let v = output.volumePercent(.output) { s += " (volume \(v) percent)" }
            if output.isMuted(.output) == true { s += ", muted" }
            parts.append(s)
        } else {
            parts.append("No output device")
        }
        return parts.joined(separator: ". ") + "."
    }
}
