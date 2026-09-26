import Foundation
import IOBluetooth

/// Bluetooth device connect / disconnect via IOBluetooth user notifications.
final class BluetoothMonitor: NSObject, EventMonitor {
    var onEvent: ((String) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []

    func start() {
        stop()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onEvent?("bluetooth.connected")
        if let note = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
            disconnectNotifications.append(note)
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onEvent?("bluetooth.disconnected")
        notification.unregister()
        disconnectNotifications.removeAll { $0 == notification }
    }
}
