import CLibUSB
import Foundation

/// Where a USB device is plugged in, which is what libmtp needs to open it.
public struct USBDeviceAddress: Hashable, Sendable {
    public let bus: UInt8
    public let address: UInt8
    public let vendorID: UInt16
    public let productID: UInt16

    public init(bus: UInt8, address: UInt8, vendorID: UInt16, productID: UInt16) {
        self.bus = bus
        self.address = address
        self.vendorID = vendorID
        self.productID = productID
    }
}

/// Garmin's USB devices, found through libusb, which only reads their descriptors. Nothing else on the bus is looked
/// at: libmtp's own scan (`LIBMTP_Detect_Raw_Devices`) opens every USB device missing from its table and sends
/// requests to some of them. The QMapShack libmtp access on macOS (`CDeviceWatcherMac`, by the same author) does the
/// same.
public enum GarminUSB {
    public static let vendorID: UInt16 = 0x091E

    /// The Garmin devices plugged in now.
    public static func devices() -> [USBDeviceAddress] {
        var context: OpaquePointer?
        guard libusb_init(&context) == 0 else { return [] }
        defer { libusb_exit(context) }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count > 0, let list else { return [] }
        defer { libusb_free_device_list(list, 1) }
        return (0..<count).compactMap { list[$0].flatMap(address(of:)) }.filter { $0.vendorID == vendorID }
    }

    fileprivate static func address(of device: OpaquePointer) -> USBDeviceAddress? {
        var descriptor = libusb_device_descriptor()
        guard libusb_get_device_descriptor(device, &descriptor) == 0 else { return nil }
        return USBDeviceAddress(
            bus: libusb_get_bus_number(device), address: libusb_get_device_address(device),
            vendorID: descriptor.idVendor, productID: descriptor.idProduct
        )
    }
}

/// Reports Garmin USB devices as they are plugged in and out, through libusb hotplug, on a thread of its own.
public final class GarminUSBWatcher: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// A device plugged in. `present` is true for one that was already there when watching began.
        case arrived(USBDeviceAddress, present: Bool)
        case left(USBDeviceAddress)
    }

    private let handler: @Sendable (Event) -> Void
    private var context: OpaquePointer?
    private var handle: libusb_hotplug_callback_handle = 0
    private var thread: Thread?
    private let stopping = Atomic()
    /// True while registering, when libusb reports the devices already plugged in.
    private var enumerating = false

    /// Starts watching. Returns nil if libusb or its hotplug support is not available. `handler` is called on the
    /// watcher's thread; the devices already plugged in are reported before this returns.
    public init?(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
        guard libusb_init(&context) == 0 else { return nil }
        guard libusb_has_capability(UInt32(LIBUSB_CAP_HAS_HOTPLUG.rawValue)) != 0 else {
            libusb_exit(context)
            return nil
        }
        enumerating = true
        let events = Int32(LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED.rawValue | LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT.rawValue)
        let status = libusb_hotplug_register_callback(
            context, events, Int32(LIBUSB_HOTPLUG_ENUMERATE.rawValue), Int32(GarminUSB.vendorID),
            LIBUSB_HOTPLUG_MATCH_ANY, LIBUSB_HOTPLUG_MATCH_ANY, hotplugCallback,
            Unmanaged.passUnretained(self).toOpaque(), &handle
        )
        enumerating = false
        guard status == 0 else {
            libusb_exit(context)
            return nil
        }
        let context = context
        let stopping = stopping
        let thread = Thread {
            while !stopping.value {
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                libusb_handle_events_timeout_completed(context, &timeout, nil)
            }
        }
        thread.name = "BaseCampMTP.usb"
        thread.start()
        self.thread = thread
    }

    deinit {
        stop()
    }

    /// Stops watching; no event is reported after this returns.
    public func stop() {
        guard let context, !stopping.value else { return }
        stopping.value = true
        libusb_hotplug_deregister_callback(context, handle)
        libusb_interrupt_event_handler(context)
        while thread?.isFinished == false {
            usleep(1000)
        }
        libusb_exit(context)
        self.context = nil
    }

    fileprivate func report(_ device: OpaquePointer, arrived: Bool) {
        guard !stopping.value, let address = GarminUSB.address(of: device) else { return }
        handler(arrived ? .arrived(address, present: enumerating) : .left(address))
    }
}

private let hotplugCallback: libusb_hotplug_callback_fn = { _, device, event, data in
    guard let device, let data else { return 0 }
    let watcher = Unmanaged<GarminUSBWatcher>.fromOpaque(data).takeUnretainedValue()
    watcher.report(device, arrived: event == LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED)
    return 0
}

/// A flag shared between threads.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
