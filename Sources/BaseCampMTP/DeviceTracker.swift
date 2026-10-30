import Foundation

/// Which Garmin devices are plugged in, and when each is next to be opened. It decides; the caller opens.
///
/// A device that has just appeared is opened `settleDelay` later: a booting Edge 1040 shows up on USB for about a
/// millisecond and leaves again. One that was already plugged in when watching began is opened at once. A failed
/// open (not MTP yet, no storage yet, held by Garmin Express or another app) is tried again after each of
/// `retryDelays`, then given up until the device is plugged in again or `retryGivenUp` is called. As the QMapShack
/// device watcher on macOS (`CDeviceWatcherMac`, by the same author) does.
public struct DeviceTracker: Equatable, Sendable {
    public static let settleDelay: TimeInterval = 3
    public static let retryDelays: [TimeInterval] = [2.5, 5, 10, 20, 40]

    public struct Plugged: Equatable, Sendable {
        public let address: USBDeviceAddress
        /// Tells a device plugged in again at the same address from the earlier one.
        public let serial: Int
        var next: Date
        var failures = 0
        /// Opened, or given up.
        var done = false
        var givenUp = false
    }

    public private(set) var plugged: [Plugged] = []
    private var serial = 0

    public init() {}

    public var isEmpty: Bool { plugged.isEmpty }

    public mutating func arrived(_ address: USBDeviceAddress, present: Bool, now: Date) {
        // Watching may report a device both as present and as arriving.
        guard !plugged.contains(where: { $0.address == address }) else { return }
        serial += 1
        plugged.append(Plugged(address: address, serial: serial, next: present ? now : now + Self.settleDelay))
    }

    public mutating func left(_ address: USBDeviceAddress) {
        plugged.removeAll { $0.address == address }
    }

    /// The serial of the device plugged in at `address`, if one is.
    public func serial(of address: USBDeviceAddress) -> Int? {
        plugged.first { $0.address == address }?.serial
    }

    /// The first device due to be opened now.
    public func due(now: Date) -> Plugged? {
        plugged.first { !$0.done && $0.next <= now }
    }

    /// When the next device not yet due is to be opened, if any is waiting.
    public func nextAttempt(after now: Date) -> Date? {
        plugged.filter { !$0.done && $0.next > now }.map(\.next).min()
    }

    /// Whether some device is waiting to be opened, now or later.
    public var isWaiting: Bool {
        plugged.contains { !$0.done }
    }

    /// The device was opened. Ignored if it is not the one that was tried (`serial`).
    public mutating func opened(_ address: USBDeviceAddress, serial: Int) {
        guard let index = index(address, serial) else { return }
        plugged[index].done = true
    }

    /// The device could not be opened. Returns true when it is given up.
    @discardableResult
    public mutating func failed(_ address: USBDeviceAddress, serial: Int, now: Date) -> Bool {
        guard let index = index(address, serial) else { return false }
        let failures = plugged[index].failures
        plugged[index].failures += 1
        guard failures < Self.retryDelays.count else {
            plugged[index].done = true
            plugged[index].givenUp = true
            return true
        }
        plugged[index].next = now + Self.retryDelays[failures]
        return false
    }

    /// Tries the given-up devices again, at once. Opened devices are left alone.
    public mutating func retryGivenUp(now: Date) {
        for index in plugged.indices where plugged[index].givenUp {
            plugged[index].done = false
            plugged[index].givenUp = false
            plugged[index].failures = 0
            plugged[index].next = now
        }
    }

    private func index(_ address: USBDeviceAddress, _ serial: Int) -> Int? {
        plugged.firstIndex { $0.address == address && $0.serial == serial }
    }
}
