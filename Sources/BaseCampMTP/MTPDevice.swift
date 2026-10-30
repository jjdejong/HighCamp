import Foundation

/// The one way into the MTP device. libmtp is not thread-safe, so every piece of device work runs here, one at a
/// time, on a private serial queue (not Swift's shared thread pool, since libmtp blocks). The connection is opened
/// on first use, kept for the next piece of work, and closed after `idleTimeout` with nothing to do, so other apps
/// can reach the device. It is also closed after an error that may mean the device has gone.
public actor MTPDevice {
    private let queue = DispatchSerialQueue(label: "BaseCampMTP.device")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var open: (@Sendable () throws -> any MTPLink)?
    private let idleTimeout: Duration
    private var link: (any MTPLink)?
    private var storages: [MTPStorage]?
    /// Counts pieces of work, so an idle close only happens when nothing ran since it was scheduled.
    private var generation = 0

    public init(
        idleTimeout: Duration = .seconds(10),
        open: (@Sendable () throws -> any MTPLink)? = nil
    ) {
        self.idleTimeout = idleTimeout
        self.open = open
    }

    /// What the device is and its storages. A kept connection may belong to a device that was unplugged since, so
    /// after a failure on a kept connection this tries once more with a new one.
    public func status() throws -> (identity: MTPDeviceIdentity, storages: [MTPStorage]) {
        let reused = link != nil
        do {
            return try perform { link, _ in (link.identity, try readStorages(link)) }
        } catch where reused && !Self.isLogical(error) {
            return try perform { link, _ in (link.identity, try readStorages(link)) }
        }
    }

    /// Runs `work` with the connection and the device's main storage (see `garminStorages`). Work runs to the end
    /// before the next starts. The storages are read when the connection opens and by `status()`, not for each
    /// piece of work.
    public func perform<T>(_ work: (any MTPLink, MTPStorage) throws -> T) throws -> T {
        try performOnStorages { link, storages in try work(link, storages[0]) }
    }

    /// Runs `work` with the connection and every storage with a Garmin folder, the main one first, such as the
    /// internal storage and a memory card.
    public func performOnStorages<T>(_ work: (any MTPLink, [MTPStorage]) throws -> T) throws -> T {
        generation += 1
        defer { scheduleIdleClose() }
        do {
            let link = try connection()
            let storages = try storages ?? readStorages(link)
            guard !storages.isEmpty else {
                throw MTPError.operationFailed("The device reports no storage.")
            }
            return try work(link, storages)
        } catch {
            if !Self.isLogical(error) { close() }
            throw error
        }
    }

    /// Sets how the next connection is opened, such as `{ try MTPConnection.open(address) }` for the device plugged
    /// in there, and closes the current one. With nil, work fails with `MTPError.noDeviceAttached`.
    public func use(_ open: (@Sendable () throws -> any MTPLink)?) {
        close()
        self.open = open
    }

    /// Closes the connection now. The next piece of work opens a new one.
    public func close() {
        link = nil
        storages = nil
    }

    private func readStorages(_ link: any MTPLink) throws -> [MTPStorage] {
        let read = Self.garminStorages(try link.storages(), link)
        storages = read
        return read
    }

    /// The storages with a Garmin folder, the one whose Garmin folder holds GarminDevice.xml first: the device's
    /// own, where courses and activities are, while a memory card holds maps and files too. A device with no Garmin
    /// folder anywhere keeps all its storages. As the QMapShack device access on macOS does.
    static func garminStorages(_ storages: [MTPStorage], _ link: any MTPLink) -> [MTPStorage] {
        var main: [MTPStorage] = []
        var others: [MTPStorage] = []
        for storage in storages {
            guard let garmin = try? link.entries(in: ["Garmin"], storageID: storage.id) else { continue }
            let described = garmin.contains { !$0.isFolder && MTPTransfers.sameName($0.name, "GarminDevice.xml") }
            if described { main.append(storage) } else { others.append(storage) }
        }
        let found = main + others
        return found.isEmpty ? storages : found
    }

    var isOpen: Bool { link != nil }

    private func connection() throws -> any MTPLink {
        if let link { return link }
        guard let open else { throw MTPError.noDeviceAttached }
        let opened = try open()
        link = opened
        return opened
    }

    private func scheduleIdleClose() {
        let scheduled = generation
        Task {
            try? await Task.sleep(for: idleTimeout)
            if generation == scheduled { close() }
        }
    }

    /// Errors about the request rather than the connection, which leave the connection usable.
    private static func isLogical(_ error: Error) -> Bool {
        switch error as? MTPError {
        case .alreadyExists, .notEnoughSpace, .cancelled, .folderNotFound: true
        default: false
        }
    }
}
