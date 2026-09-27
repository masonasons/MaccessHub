import Darwin
import Foundation
import IOKit

/// Per-process CPU and memory figures, aggregated by process name so that a
/// browser's dozen helper processes read as one entry.
///
/// Uses `/usr/bin/top`, which carries the task-port entitlement needed to read
/// root-owned processes such as WindowServer; libproc refuses those from an
/// ordinary app.
enum ProcessStats {
    struct Entry {
        var name: String
        var value: Double
    }

    /// Processes using the most GPU time over `interval` seconds, as percent of
    /// wall time, from the accelerator user clients' accumulated GPU time.
    /// Calls back on the main thread.
    static func topGPU(limit: Int = 5, interval: TimeInterval = 0.6, completion: @escaping ([Entry]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let first = gpuTimes()
            let start = DispatchTime.now()
            Thread.sleep(forTimeInterval: interval)
            let second = gpuTimes()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
            var byName: [String: Double] = [:]
            for (pid, after) in second {
                let before = first[pid]?.time ?? after.time
                guard after.time >= before else { continue }
                byName[after.name, default: 0] += Double(after.time - before) / elapsed * 100
            }
            let top = byName.map { Entry(name: $0.key, value: $0.value) }
                .filter { $0.value >= 0.5 }
                .sorted { $0.value > $1.value }
                .prefix(limit)
            DispatchQueue.main.async { completion(Array(top)) }
        }
    }

    /// pid → (name, accumulated GPU nanoseconds) for every process with an accelerator client.
    private static func gpuTimes() -> [pid_t: (name: String, time: UInt64)] {
        var result: [pid_t: (String, UInt64)] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var accelerator = IOIteratorNext(iterator)
        while accelerator != 0 {
            defer { IOObjectRelease(accelerator); accelerator = IOIteratorNext(iterator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            var client = IOIteratorNext(children)
            while client != 0 {
                defer { IOObjectRelease(client); client = IOIteratorNext(children) }
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                // "pid 179, WindowServer"
                let parts = creator.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let pid = pid_t(parts[0].replacingOccurrences(of: "pid ", with: "")) else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                let name = fullName(pid: pid) ?? parts[1]
                let existing = result[pid]?.1 ?? 0
                result[pid] = (name, existing + time)
            }
        }
        return result
    }

    private static func fullName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let component = (String(cString: buffer) as NSString).lastPathComponent
        return component.isEmpty ? nil : component
    }

    private struct Row {
        var pid: pid_t
        var cpu: Double
        var memoryBytes: Double
        var command: String
    }

    /// Processes using the most CPU over about one second, as percent of one core.
    /// Calls back on the main thread.
    static func topCPU(limit: Int = 5, completion: @escaping ([Entry]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Two samples: the first is a lifetime average, the second is real usage since the first.
            let rows = runTop(["-l", "2", "-s", "1", "-o", "cpu", "-n", "20"]).last ?? []
            let entries = aggregate(rows, by: \.cpu).filter { $0.value >= 0.5 }.prefix(limit)
            DispatchQueue.main.async { completion(Array(entries)) }
        }
    }

    /// Processes with the largest memory footprint, in bytes. Calls back on the main thread.
    static func topMemory(limit: Int = 5, completion: @escaping ([Entry]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = runTop(["-l", "1", "-o", "mem", "-n", "20"]).last ?? []
            let entries = aggregate(rows, by: \.memoryBytes).prefix(limit)
            DispatchQueue.main.async { completion(Array(entries)) }
        }
    }

    private static func aggregate(_ rows: [Row], by key: KeyPath<Row, Double>) -> [Entry] {
        var byName: [String: Double] = [:]
        for row in rows { byName[name(of: row), default: 0] += row[keyPath: key] }
        return byName.map { Entry(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
    }

    /// Full executable name from the PID; falls back to top's (truncated) column.
    private static func name(of row: Row) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(row.pid, &buffer, UInt32(buffer.count)) > 0 {
            let component = (String(cString: buffer) as NSString).lastPathComponent
            if !component.isEmpty { return component }
        }
        return row.command
    }

    /// Runs top and returns one array of rows per sample.
    private static func runTop(_ arguments: [String]) -> [[Row]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = arguments + ["-stats", "pid,cpu,mem,command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var samples: [[Row]] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4 else { continue }
            if fields[0] == "PID" { samples.append([]); continue }
            guard !samples.isEmpty, let pid = pid_t(fields[0]), let cpu = Double(fields[1]) else { continue }
            let command = fields[3...].joined(separator: " ")
            samples[samples.count - 1].append(Row(pid: pid, cpu: cpu, memoryBytes: parseMemory(String(fields[2])),
                                                  command: command))
        }
        return samples
    }

    /// top prints memory like `690M+`, `58M-`, `1.2G`, `512K`.
    private static func parseMemory(_ text: String) -> Double {
        var s = text
        while let last = s.last, last == "+" || last == "-" { s.removeLast() }
        guard let unit = s.last else { return 0 }
        let number = Double(s.dropLast()) ?? Double(s) ?? 0
        switch unit {
        case "K": return number * 1024
        case "M": return number * 1024 * 1024
        case "G": return number * 1024 * 1024 * 1024
        case "B": return number
        default: return Double(s) ?? 0
        }
    }
}
