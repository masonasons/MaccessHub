import AppKit
import Darwin
import Foundation
import IOKit

/// Raw system measurements used by the resource-monitor feature.
enum SystemStats {
    struct CPUTicks {
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        var total: UInt64 { user + system + idle + nice }
    }

    static func cpuTicks() -> CPUTicks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var ticks = CPUTicks()
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            ticks.user += UInt64(info[base + Int(CPU_STATE_USER)])
            ticks.system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            ticks.idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
            ticks.nice += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        return ticks
    }

    struct CPUUsage { var overall: Double; var user: Double; var system: Double }

    /// Samples the CPU over `interval` seconds and calls back on the main thread.
    static func cpuUsage(interval: TimeInterval = 0.5, completion: @escaping (CPUUsage?) -> Void) {
        guard let first = cpuTicks() else { completion(nil); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
            guard let second = cpuTicks() else { DispatchQueue.main.async { completion(nil) }; return }
            let total = Double(second.total &- first.total)
            guard total > 0 else { DispatchQueue.main.async { completion(nil) }; return }
            let user = Double((second.user &- first.user) + (second.nice &- first.nice)) / total * 100
            let system = Double(second.system &- first.system) / total * 100
            DispatchQueue.main.async { completion(CPUUsage(overall: user + system, user: user, system: system)) }
        }
    }

    /// GPU utilisation in percent from the IOAccelerator driver's performance
    /// statistics (Apple silicon and most AMD/Intel GPUs). Nil if unavailable.
    static func gpuUsage() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? Int
            if let value { best = max(best ?? 0, value) }
        }
        return best
    }

    struct MemoryUsage {
        var total: UInt64, used: UInt64, wired: UInt64, compressed: UInt64, appMemory: UInt64
        var percentUsed: Int { total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0 }
    }

    static func memoryUsage() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        // Activity Monitor's "App Memory": internal pages minus purgeable ones.
        let internalPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let app = internalPages * page
        let used = app + wired + compressed
        return MemoryUsage(total: ProcessInfo.processInfo.physicalMemory, used: used,
                           wired: wired, compressed: compressed, appMemory: app)
    }

    struct VolumeUsage {
        var name: String, format: String, total: Int64, available: Int64
        var used: Int64 { max(0, total - available) }
        var percentUsed: Int { total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0 }
    }

    static func volumes(browsableOnly: Bool) -> [VolumeUsage] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeUsage] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if browsableOnly, values.volumeIsBrowsable == false { continue }
            guard let total = values.volumeTotalCapacity, total > 0 else { continue }
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            result.append(VolumeUsage(name: values.volumeLocalizedName ?? url.lastPathComponent,
                                      format: values.volumeLocalizedFormatDescription ?? "Unknown format",
                                      total: Int64(total), available: available))
        }
        return result
    }

    static func bytesToHuman(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func bytesToHuman(_ bytes: UInt64) -> String { bytesToHuman(Int64(clamping: bytes)) }

    static func uptimeDescription() -> String {
        let total = Int(ProcessInfo.processInfo.systemUptime)
        return durationDescription(seconds: total)
    }

    static func durationDescription(seconds total: Int) -> String {
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append(days == 1 ? "1 day" : "\(days) days") }
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        if parts.isEmpty { return "less than a minute" }
        return parts.joined(separator: ", ")
    }

    static func minutesDescription(_ minutes: Int) -> String {
        durationDescription(seconds: minutes * 60)
    }

    static func osVersionDescription() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var s = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { s += ".\(v.patchVersion)" }
        let full = ProcessInfo.processInfo.operatingSystemVersionString
        if let open = full.range(of: "(Build "), let close = full.range(of: ")", range: open.upperBound..<full.endIndex) {
            s += ", build \(full[open.upperBound..<close.lowerBound])"
        }
        return s
    }

    static func clipboardDescription(readLimit: Int) -> String {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            if text.isEmpty { return "The clipboard is empty." }
            let count = text.count
            if count >= readLimit {
                let words = text.split { $0.isWhitespace || $0.isNewline }.count
                return "The clipboard contains a large amount of text: \(count) characters, about \(words) words."
            }
            return "Clipboard contains: \(text)"
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let names = urls.map(\.lastPathComponent)
            return urls.count == 1 ? "Clipboard contains the file \(names[0])."
                : "Clipboard contains \(urls.count) files: \(names.joined(separator: ", "))"
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self]) { return "Clipboard contains an image." }
        if let types = pasteboard.types, !types.isEmpty {
            return "Clipboard contains data of type \(types[0].rawValue)."
        }
        return "The clipboard is empty."
    }
}
