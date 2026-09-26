import Foundation
import IOKit
import IOKit.usb

/// USB device arrival and removal through IOKit matching notifications.
final class USBMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?

    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    func start() {
        stop()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let addedCallback: IOServiceMatchingCallback = { refcon, iterator in
            USBMonitor.drain(iterator)
            guard let refcon else { return }
            Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue().onEvent?("usb.connected")
        }
        let removedCallback: IOServiceMatchingCallback = { refcon, iterator in
            USBMonitor.drain(iterator)
            guard let refcon else { return }
            Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue().onEvent?("usb.disconnected")
        }

        // Each call consumes the matching dictionary, so create one per registration.
        if IOServiceAddMatchingNotification(port, kIOMatchedNotification, IOServiceMatching(kIOUSBDeviceClassName),
                                            addedCallback, refcon, &addedIterator) == KERN_SUCCESS {
            Self.drain(addedIterator) // arm the notification without firing for existing devices
        }
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(kIOUSBDeviceClassName),
                                            removedCallback, refcon, &removedIterator) == KERN_SUCCESS {
            Self.drain(removedIterator)
        }
    }

    func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port {
            IONotificationPortDestroy(port)
        }
        port = nil
    }

    private static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}
