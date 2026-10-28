import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import Network
import os

/// Spoken network status: what you are connected to and how fast data is
/// moving right now, plus (on a double press) which processes are moving it.
final class NetworkInfoFeature: NSObject, CLLocationManagerDelegate {
    let speaker: Speaker
    var topProcessCount = 5

    private let log = Logger(subsystem: "com.maccesshub.app", category: "network")
    private let location = CLLocationManager()
    private let queue = DispatchQueue(label: "com.maccesshub.network", qos: .userInitiated)

    init(speaker: Speaker) {
        self.speaker = speaker
        super.init()
        location.delegate = self
    }

    // MARK: Location (needed by macOS before it reveals the Wi-Fi network name)

    var locationStatus: CLAuthorizationStatus { location.authorizationStatus }

    var locationAuthorized: Bool {
        location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorized
    }

    func requestLocationIfNeeded() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log.info("Location authorization: \(manager.authorizationStatus.rawValue, privacy: .public)")
    }

    // MARK: Single press

    func speakNetwork() {
        requestLocationIfNeeded()
        queue.async { [weak self] in
            guard let self else { return }
            let message = describeNetwork()
            DispatchQueue.main.async { self.speaker.speak(message) }
        }
    }

    /// Blocks for about a second to measure throughput; call off the main thread.
    func describeNetwork() -> String {
        let path = currentPath()
        guard path.status == .satisfied, let interface = path.availableInterfaces.first else {
            return "Not connected to any network."
        }
        var parts: [String] = []
        switch interface.type {
        case .wifi:
            var wifi = "Wi-Fi"
            if let client = CWWiFiClient.shared().interface(withName: interface.name) ?? CWWiFiClient.shared().interface() {
                if let ssid = client.ssid() {
                    wifi += " network \(ssid)"
                } else if !locationAuthorized {
                    wifi += ", network name needs the Location permission"
                }
                let rssi = client.rssiValue()
                if rssi != 0 { wifi += ", signal \(rssi) dBm (\(Self.signalWord(rssi)))" }
                let rate = client.transmitRate()
                if rate > 0 { wifi += ", link \(Self.megabits(rate))" }
            }
            parts.append(wifi)
        case .wiredEthernet: parts.append("Ethernet on \(interface.name)")
        case .cellular: parts.append("Cellular")
        case .loopback: parts.append("Loopback")
        case .other: parts.append("Network interface \(interface.name)")
        @unknown default: parts.append("Network interface \(interface.name)")
        }
        if path.usesInterfaceType(.other), interface.type != .other {
            // A VPN or similar utun interface is carrying traffic too.
            parts.append("VPN active")
        }
        if let address = Self.ipv4Address(of: interface.name) { parts.append("IP \(address)") }

        let first = Self.byteCounters(of: interface.name)
        Thread.sleep(forTimeInterval: 1)
        let second = Self.byteCounters(of: interface.name)
        if let first, let second {
            let down = Double(second.received &- first.received)
            let up = Double(second.sent &- first.sent)
            parts.append("Receiving \(Self.rate(down)), sending \(Self.rate(up))")
        }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: Double press

    func speakTopNetworkProcesses() {
        speaker.speak("Measuring network usage.")
        let limit = topProcessCount
        queue.async { [weak self] in
            guard let self else { return }
            let entries = Self.topProcesses(limit: limit)
            let message: String
            if entries.isEmpty {
                message = "No processes are moving data right now."
            } else {
                let parts = entries.map { "\($0.name) receiving \(Self.rate($0.received)), sending \(Self.rate($0.sent))" }
                message = "Top network: " + parts.joined(separator: ". ") + "."
            }
            DispatchQueue.main.async { self.speaker.speak(message) }
        }
    }

    struct ProcessTraffic { var name: String; var received: Double; var sent: Double }

    /// Per-process bytes over one second, from `nettop` in delta mode (it has
    /// the network-statistics entitlement an ordinary app lacks). About five
    /// seconds wall time.
    static func topProcesses(limit: Int) -> [ProcessTraffic] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-d", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        // Two samples, each headed by ",bytes_in,bytes_out,"; the second is the delta.
        var sample = 0
        var byName: [String: ProcessTraffic] = [:]
        for line in output.split(separator: "\n") {
            if line.hasPrefix(",bytes_in") { sample += 1; continue }
            guard sample == 2 else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let received = Double(fields[1]), let sent = Double(fields[2]) else { continue }
            // "Google Chrome Helper.1234" → strip the pid suffix.
            var name = String(fields[0])
            if let dot = name.lastIndex(of: "."), Int(name[name.index(after: dot)...]) != nil { name = String(name[..<dot]) }
            var entry = byName[name] ?? ProcessTraffic(name: name, received: 0, sent: 0)
            entry.received += received
            entry.sent += sent
            byName[name] = entry
        }
        return byName.values.filter { $0.received + $0.sent >= 1024 }
            .sorted { $0.received + $0.sent > $1.received + $1.sent }
            .prefix(limit).map { $0 }
    }

    // MARK: Helpers

    private func currentPath() -> NWPath {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var result: NWPath?
        monitor.pathUpdateHandler = { path in
            if result == nil { result = path; semaphore.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "com.maccesshub.network.path"))
        _ = semaphore.wait(timeout: .now() + 1)
        let path = result ?? monitor.currentPath
        monitor.cancel()
        return path
    }

    static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    static func byteCounters(of interface: String) -> (received: UInt64, sent: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        return nil
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b < 1024 { return "\(Int(b)) bytes per second" }
        if b < 1024 * 1024 { return String(format: "%.0f KB per second", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB per second", b / (1024 * 1024)) }
        return String(format: "%.2f GB per second", b / (1024 * 1024 * 1024))
    }

    static func megabits(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.1f gigabits", mbps / 1000) : "\(Int(mbps)) megabits"
    }

    static func signalWord(_ rssi: Int) -> String {
        switch rssi {
        case ..<(-80): return "very weak"
        case ..<(-70): return "weak"
        case ..<(-60): return "fair"
        case ..<(-50): return "good"
        default: return "excellent"
        }
    }
}
