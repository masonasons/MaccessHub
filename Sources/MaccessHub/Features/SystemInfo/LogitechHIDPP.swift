import Foundation
import IOKit.hid
import os

/// Battery levels for Logitech devices that macOS itself does not report,
/// asked directly over Logitech's HID++ 2.0 protocol (the same thing Logi
/// Options+ does). Covers devices connected over Bluetooth; devices behind a
/// Bolt or Unifying receiver are not addressed yet.
enum LogitechHIDPP {
    struct Reading {
        var name: String
        var percent: Int
        var charging: Bool
    }

    enum Failure { case notPermitted, noReply }

    struct Result {
        var readings: [Reading] = []
        /// Product names that were found but could not be opened or did not answer.
        var failures: [(name: String, failure: Failure)] = []
    }

    private static let log = Logger(subsystem: "com.maccesshub.app", category: "hidpp")
    private static let vendorID = 0x046D
    private static let longReport: UInt8 = 0x11
    private static let bluetoothDeviceIndex: UInt8 = 0xFF
    private static let softwareID: UInt8 = 0x0A

    /// Runs on its own thread because HID callbacks need a run loop. Calls back on the main thread.
    static func query(completion: @escaping (Result) -> Void) {
        let thread = Thread {
            let result = queryOnCurrentThread()
            DispatchQueue.main.async { completion(result) }
        }
        thread.name = "com.maccesshub.hidpp"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static func queryOnCurrentThread() -> Result {
        var result = Result()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var seen: Set<String> = []
        for device in devices {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
            let outSize = IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
            // HID++ long reports are 20 bytes; the keyboard/mouse collections without them are not usable.
            guard outSize >= 20, !seen.contains(name) else { continue }
            seen.insert(name)
            let session = Session(device: device)
            switch session.open() {
            case kIOReturnSuccess: break
            case kIOReturnNotPermitted, kIOReturnNotPrivileged:
                log.error("Input Monitoring denied; cannot open \(name)")
                result.failures.append((name, .notPermitted)); continue
            case let status:
                log.error("Could not open \(name): \(status)")
                result.failures.append((name, .noReply)); continue
            }
            defer { session.close() }
            if let reading = session.readBattery(name: name) {
                log.debug("\(name): \(reading.percent)% charging=\(reading.charging)")
                result.readings.append(reading)
            } else {
                log.error("\(name) did not answer the HID++ battery request")
                result.failures.append((name, .noReply))
            }
        }
        return result
    }

    /// One open HID device with an input-report queue.
    private final class Session {
        let device: IOHIDDevice
        private var buffer = [UInt8](repeating: 0, count: 64)
        private var responses: [[UInt8]] = []

        init(device: IOHIDDevice) { self.device = device }

        func open() -> IOReturn {
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else { return status }
            let context = Unmanaged.passUnretained(self).toOpaque()
            buffer.withUnsafeMutableBufferPointer { buf in
                IOHIDDeviceRegisterInputReportCallback(device, buf.baseAddress!, buf.count, { context, _, _, _, id, report, length in
                    guard let context else { return }
                    let session = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
                    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    let reportID = UInt8(truncatingIfNeeded: id)
                    session.responses.append(bytes.first == reportID ? bytes : [reportID] + bytes)
                }, context)
            }
            return status
        }

        func close() {
            IOHIDDeviceRegisterInputReportCallback(device, &buffer, buffer.count, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        /// Sends a HID++ request and waits for the matching reply (or an error report).
        private func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 1.5) -> [UInt8]? {
            responses.removeAll()
            let header: [UInt8] = [longReport, bluetoothDeviceIndex, featureIndex, (function << 4) | softwareID]
            var report = header + params
            report += [UInt8](repeating: 0, count: max(0, 20 - report.count))
            let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(longReport), &report, report.count)
            guard status == kIOReturnSuccess else { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.02, false)
                if let reply = responses.first(where: { $0.count >= 7 && $0[2] == featureIndex && $0[3] == header[3] }) {
                    return reply
                }
                if responses.contains(where: { $0.count >= 4 && $0[2] == 0xFF }) { return nil } // HID++ error
            }
            return nil
        }

        /// Root feature function 0: look up the index of a feature by ID.
        private func featureIndex(_ featureID: UInt16) -> UInt8? {
            guard let reply = request(featureIndex: 0, function: 0, params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]),
                  reply[4] != 0 else { return nil }
            return reply[4]
        }

        func readBattery(name: String) -> Reading? {
            // 0x1004 UNIFIED_BATTERY, function 1 get_status: [state_of_charge %, level, charging status]
            if let index = featureIndex(0x1004), let reply = request(featureIndex: index, function: 1) {
                let percent = Int(reply[4])
                let status = reply[6] // 0 discharging, 1 charging, 2 slow charging, 3 complete, 4 error
                if percent > 0 { return Reading(name: name, percent: percent, charging: status == 1 || status == 2) }
            }
            // 0x1000 BATTERY_STATUS, function 0: [discharge level %, next level, status]
            if let index = featureIndex(0x1000), let reply = request(featureIndex: index, function: 0) {
                let percent = Int(reply[4])
                let status = reply[6] // 1, 2, 4 = charging variants
                if percent > 0 { return Reading(name: name, percent: percent, charging: [1, 2, 4].contains(status)) }
            }
            return nil
        }
    }
}
