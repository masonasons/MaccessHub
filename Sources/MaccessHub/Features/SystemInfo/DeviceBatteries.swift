import Foundation
import IOKit.ps

/// Battery levels of connected accessories: Bluetooth devices via
/// system_profiler (which knows AirPods' left/right/case levels) plus anything
/// else that shows up as an external power source in IOKit.
enum DeviceBatteries {
    struct Device {
        var name: String
        /// Ordered label/percent pairs, e.g. [("left", 70), ("right", 72), ("case", 82)] or [("", 60)].
        var levels: [(label: String, percent: Int)]
        var charging = false
        /// Shown instead of "no battery information" when a reading was blocked.
        var note: String? = nil
    }

    /// Calls back on the main thread.
    static func connectedDevices(completion: @escaping ([Device]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var devices = bluetoothDevices()
            for source in powerSourceAccessories() where !devices.contains(where: { $0.name == source.name }) {
                devices.append(source)
            }
            // Logitech devices report to Logi software, not macOS; ask them ourselves.
            LogitechHIDPP.query { result in
                for reading in result.readings {
                    if let i = devices.firstIndex(where: { $0.name == reading.name }) {
                        if devices[i].levels.isEmpty { devices[i].levels = [("", reading.percent)] }
                        devices[i].charging = reading.charging
                    } else {
                        devices.append(Device(name: reading.name, levels: [("", reading.percent)], charging: reading.charging))
                    }
                }
                for failure in result.failures where failure.failure == .notPermitted {
                    if let i = devices.firstIndex(where: { $0.name == failure.name }), devices[i].levels.isEmpty {
                        devices[i].note = "battery needs the Input Monitoring permission"
                    }
                }
                completion(devices)
            }
        }
    }

    static func describe(_ devices: [Device]) -> String {
        guard !devices.isEmpty else { return "No connected devices." }
        let parts = devices.map { device -> String in
            if device.levels.isEmpty { return "\(device.name): \(device.note ?? "no battery information")" }
            let levels = device.levels.map { $0.label.isEmpty ? "\($0.percent) percent" : "\($0.label) \($0.percent) percent" }
            return "\(device.name): " + levels.joined(separator: ", ") + (device.charging ? ", charging" : "")
        }
        let count = devices.count == 1 ? "1 device" : "\(devices.count) devices"
        return "\(count). " + parts.joined(separator: ". ") + "."
    }

    private static func bluetoothDevices() -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]],
              let connected = sections.first?["device_connected"] as? [[String: Any]] else { return [] }

        var devices: [Device] = []
        for entry in connected {
            for (name, value) in entry {
                let props = value as? [String: Any] ?? [:]
                var levels: [(String, Int)] = []
                let keys: [(String, String)] = [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "left"),
                                                ("device_batteryLevelRight", "right"), ("device_batteryLevelCase", "case")]
                for (key, label) in keys {
                    if let percent = percent(props[key]) { levels.append((label, percent)) }
                }
                devices.append(Device(name: name, levels: levels))
            }
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return (value as? NSNumber)?.intValue }
        return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// Accessories that macOS lists as power sources (some mice, keyboards, UPS units).
    private static func powerSourceAccessories() -> [Device] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var devices: [Device] = []
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String != kIOPSInternalBatteryType,
                  let name = desc[kIOPSNameKey] as? String,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            devices.append(Device(name: name, levels: [("", percent)]))
        }
        return devices
    }
}
