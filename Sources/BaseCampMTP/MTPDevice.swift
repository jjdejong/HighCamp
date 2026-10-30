import Foundation

/// The one way into the MTP device. libmtp is not thread-safe, so every piece of device work runs here, one at a
/// time, on a private serial queue (not Swift's shared thread pool, since libmtp blocks). The connection is opened
/// on first use, kept for the next piece of work, and closed after `idleTimeout` with nothing to do, so other apps
/// can reach the device. It is also closed after an error that may mean the device has gone.
public actor MTPDevice {
    private let queue = DispatchSerialQueue(label: "BaseCampMTP.device")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let open: @Sendable () throws -> any MTPLink
    private let idleTimeout: Duration
    private var link: (any MTPLink)?
    private var storages: [MTPStorage]?
    /// Counts pieces of work, so an idle close only happens when nothing ran since it was scheduled.
    private var generation = 0

    public init(
        idleTimeout: Duration = .seconds(10),
        open: @escaping @Sendable () throws -> any MTPLink = { try MTPConnection.openFirstDevice() }
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

    /// Runs `work` with the connection and the device's first storage. Work runs to the end before the next starts.
    /// The storages are read when the connection opens and by `status()`, not for each piece of work.
    public func perform<T>(_ work: (any MTPLink, MTPStorage) throws -> T) throws -> T {
        generation += 1
        defer { scheduleIdleClose() }
        do {
            let link = try connection()
            let storages = try storages ?? readStorages(link)
            guard let storage = storages.first else {
                throw MTPError.operationFailed("The device reports no storage.")
            }
            return try work(link, storage)
        } catch {
            if !Self.isLogical(error) { close() }
            throw error
        }
    }

    /// Closes the connection now. The next piece of work opens a new one.
    public func close() {
        link = nil
        storages = nil
    }

    private func readStorages(_ link: any MTPLink) throws -> [MTPStorage] {
        let read = try link.storages()
        storages = read
        return read
    }

    var isOpen: Bool { link != nil }

    private func connection() throws -> any MTPLink {
        if let link { return link }
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
