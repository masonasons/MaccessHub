import Foundation
import IOKit

/// Battery health and electrical details from the AppleSmartBattery service.
struct BatteryDetails {
    var designCapacity: Int?        // mAh
    var fullChargeCapacity: Int?    // mAh, what a full charge holds today
    var currentCharge: Int?         // mAh
    var cycleCount: Int?
    var designCycleCount: Int?
    var voltage: Double?            // V
    var amperage: Double?           // A, negative while discharging
    var adapterName: String?
    var adapterWatts: Int?
    var systemPowerIn: Double?      // W drawn from the adapter
    var isCharging = false
    var fullyCharged = false
    var externalConnected = false

    /// Percent of design capacity a full charge still holds (System Settings' "Maximum Capacity").
    var healthPercent: Int? {
        guard let design = designCapacity, design > 0, let full = fullChargeCapacity else { return nil }
        return Int((Double(full) / Double(design) * 100).rounded())
    }

    static func read() -> BatteryDetails? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        let data = dict["BatteryData"] as? [String: Any] ?? [:]
        let adapter = dict["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        func int(_ key: String, _ source: [String: Any]) -> Int? { (source[key] as? NSNumber)?.intValue }

        var details = BatteryDetails()
        details.designCapacity = int("DesignCapacity", data)
        details.fullChargeCapacity = int("NominalChargeCapacity", data) ?? int("FullChargeCapacity", data) ?? int("AppleRawMaxCapacity", data)
        details.currentCharge = int("AppleRawCurrentCapacity", data) ?? int("RemainingCapacity", data)
        details.cycleCount = int("CycleCount", dict)
        details.designCycleCount = int("DesignCycleCount9C", dict)
        if let mv = int("Voltage", dict) { details.voltage = Double(mv) / 1000 }
        if let ma = int("InstantAmperage", dict) ?? int("Amperage", dict) {
            // Reported as an unsigned 64-bit value when negative.
            let signed = ma > Int(Int32.max) ? ma - Int(UInt32.max) - 1 : ma
            details.amperage = Double(signed) / 1000
        }
        details.adapterName = adapter["Name"] as? String ?? adapter["Description"] as? String
        details.adapterWatts = int("Watts", adapter)
        if let mw = int("SystemPowerIn", telemetry), mw > 0 { details.systemPowerIn = Double(mw) / 1000 }
        details.isCharging = (dict["IsCharging"] as? Bool) ?? false
        details.fullyCharged = (dict["FullyCharged"] as? Bool) ?? false
        details.externalConnected = (dict["ExternalConnected"] as? Bool) ?? false
        return details
    }

    /// Spoken form for the battery shortcut's double press.
    func describe() -> String {
        var parts: [String] = []
        if let health = healthPercent {
            let condition = health >= 80 ? "condition normal" : "service recommended"
            parts.append("Battery health \(health) percent of design capacity, \(condition)")
        }
        if let cycles = cycleCount {
            parts.append(designCycleCount.map { "\(cycles) of \($0) rated charge cycles" } ?? "\(cycles) charge cycles")
        }
        if let full = fullChargeCapacity, let design = designCapacity {
            parts.append("Full charge holds \(full) of \(design) milliamp hours")
        }
        if let charge = currentCharge { parts.append("Currently holding \(charge) milliamp hours") }
        if let v = voltage { parts.append(String(format: "%.1f volts", v)) }
        if let a = amperage, let v = voltage, abs(a) >= 0.05 {
            let watts = abs(a) * v
            parts.append(String(format: a < 0 ? "Discharging at %.1f watts" : "Charging at %.1f watts", watts))
        }
        if externalConnected {
            var power = "On "
            if let name = adapterName { power += name } else { power += "external power" }
            if let w = adapterWatts { power += " rated \(w) watts" }
            if let draw = systemPowerIn { power += String(format: ", system drawing %.0f watts", draw) }
            if fullyCharged { power += ", fully charged" } else if !isCharging { power += ", not charging" }
            parts.append(power)
        }
        return parts.isEmpty ? "Battery details are unavailable." : parts.joined(separator: ". ") + "."
    }
}
