import Foundation
import Network

/// Wi-Fi / Ethernet link changes and overall connectivity via NWPathMonitor.
final class NetworkMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?

    private var monitor: NWPathMonitor?
    private var wifi: Bool?
    private var ethernet: Bool?
    private var connected: Bool?

    func start() {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.update(path) }
        }
        monitor.start(queue: DispatchQueue(label: "com.maccesshub.network"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        wifi = nil
        ethernet = nil
        connected = nil
    }

    private func update(_ path: NWPath) {
        let newWifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
        let newEthernet = path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
        let newConnected = path.status == .satisfied && (path.supportsIPv4 || path.supportsIPv6)
        defer { wifi = newWifi; ethernet = newEthernet; connected = newConnected }
        // First report establishes the baseline silently.
        guard wifi != nil else { return }
        if newWifi != wifi { onEvent?(newWifi ? "network.wifiConnected" : "network.wifiDisconnected") }
        if newEthernet != ethernet { onEvent?(newEthernet ? "network.ethernetConnected" : "network.ethernetDisconnected") }
        if newConnected != connected { onEvent?(newConnected ? "network.ipv4Acquired" : "network.ipv4Released") }
    }
}
