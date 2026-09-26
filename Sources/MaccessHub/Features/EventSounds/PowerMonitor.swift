import Foundation
import IOKit.ps

/// Power source changes, charge state, and low-battery warnings.
final class PowerMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var lastSource: String?
    private var lastCharging: Bool?
    private var lastCharged: Bool?
    /// Thresholds already announced during the current discharge.
    private var announced: Set<Int> = []

    func start() {
        stop()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ refcon in
            guard let refcon else { return }
            Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue().check(initial: false)
        }, refcon)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        check(initial: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        lastSource = nil
        lastCharging = nil
        lastCharged = nil
        announced.removeAll()
    }

    private func check(initial: Bool) {
        guard let snapshot = BatteryStatus.current() else { return }
        defer {
            lastSource = snapshot.sourceType
            lastCharging = snapshot.isCharging
            lastCharged = snapshot.isCharged
        }
        guard !initial else { return }

        if snapshot.sourceType != lastSource {
            switch snapshot.sourceType {
            case "AC Power": onEvent?("power.acPower")
            case "Battery Power": onEvent?("power.batteryPower")
            case "UPS Power": onEvent?("power.upsPower")
            default: break
            }
            if snapshot.sourceType == "Battery Power" { announced.removeAll() }
        }
        if snapshot.isCharging, lastCharging == false { onEvent?("power.charging") }
        if snapshot.isCharged, lastCharged == false { onEvent?("power.charged") }

        if snapshot.sourceType == "Battery Power", let minutes = snapshot.minutesRemaining, minutes > 0 {
            for threshold in [20, 10, 5] where minutes <= threshold && !announced.contains(threshold) {
                announced.insert(threshold)
                onEvent?("power.battery\(threshold)Minutes")
                break
            }
        }
    }
}

/// Snapshot of the first battery-style power source.
struct BatteryStatus {
    var percentage: Int
    /// "AC Power", "Battery Power" or "UPS Power": whatever is currently providing power.
    var sourceType: String
    var isCharging: Bool
    var isCharged: Bool
    /// Minutes until empty (on battery) or until full (charging); nil while calculating.
    var minutesRemaining: Int?
    var hasBattery: Bool

    static func current() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? ?? "AC Power"
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let charged = desc[kIOPSIsChargedKey] as? Bool ?? false
            let minutesKey = providing == kIOPSBatteryPowerValue ? kIOPSTimeToEmptyKey : kIOPSTimeToFullChargeKey
            let minutes = desc[minutesKey] as? Int
            return BatteryStatus(percentage: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0,
                                 sourceType: providing, isCharging: charging, isCharged: charged,
                                 minutesRemaining: (minutes ?? -1) < 0 ? nil : minutes, hasBattery: true)
        }
        return BatteryStatus(percentage: 0, sourceType: providing, isCharging: false, isCharged: false,
                             minutesRemaining: nil, hasBattery: false)
    }
}
