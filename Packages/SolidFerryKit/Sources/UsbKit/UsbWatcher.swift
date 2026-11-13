import Foundation
import IOKit

/// Calls back the moment a USB interface appears or a USB device goes away, instead of
/// waiting for the next poll. Speed matters: macOS's photo service (ptpcamerad) grabs a
/// phone's MTP interface within moments of plugging in and starts reading the whole photo
/// library; whoever opens the interface first keeps it.
public final class UsbWatcher {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let onChange: () -> Void

    /// `onChange` runs on the main queue.
    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator to re-arm the notification.
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            guard let refcon else { return }
            Unmanaged<UsbWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        for (type, cls) in [(kIOFirstMatchNotification, "IOUSBHostInterface"), (kIOTerminatedNotification, "IOUSBHostDevice")] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching(cls), callback, refcon, &iterator) == KERN_SUCCESS {
                while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) } // arm
                iterators.append(iterator)
            }
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }
}
