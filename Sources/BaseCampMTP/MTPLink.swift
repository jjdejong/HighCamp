import Foundation

/// The raw operations of one open MTP connection. `MTPConnection` implements it over libmtp; tests use a fake.
/// Nothing here checks results on the device: `MTPTransfers` does that.
public protocol MTPLink: AnyObject {
    var identity: MTPDeviceIdentity { get }
    func storages() throws -> [MTPStorage]
    /// The files and folders inside `path`, for example `["Garmin", "Courses"]`.
    func entries(in path: [String], storageID: UInt32) throws -> [MTPEntry]
    /// Starts sending a file and returns libmtp's status, which is unreliable on Edge devices (0 means success).
    /// `progress` receives bytes sent and the total; returning false cancels the transfer.
    func send(
        localFile: URL, size: UInt64, to path: [String], as name: String, storageID: UInt32,
        progress: ((UInt64, UInt64) -> Bool)?
    ) throws -> Int32
    /// Asks the device to delete one object and returns libmtp's status.
    func deleteObject(_ id: UInt32) -> Int32
    func download(entryID: UInt32, to localFile: URL) throws
    /// The device's latest error text, or `fallback` when there is none.
    func lastError(fallback: String) -> String
}

/// Uploads and deletes that check their result on the device and leave nothing half-written behind.
public enum MTPTransfers {
    /// Files up to this size are read back and compared byte for byte after an upload.
    public static let byteCompareLimit: UInt64 = 100 * 1024 * 1024
    /// Space kept free on the device beyond the file itself, for the device's own bookkeeping.
    public static let spaceMargin: UInt64 = 1024 * 1024

    /// Sends a local file into `path` under `name`, then checks it on the device.
    ///
    /// Refuses to overwrite a file with the same name (ignoring case, as the device does), and refuses a file that does not fit in the free space.
    /// The device contents decide success, not libmtp's status. When the upload fails, is cancelled or does not
    /// match the local file, whatever arrived on the device under `name` is deleted.
    public static func upload(
        _ link: MTPLink,
        localFile: URL,
        to path: [String],
        as name: String,
        storageID: UInt32,
        progress: ((UInt64, UInt64) -> Bool)? = nil
    ) throws {
        let existing = try link.entries(in: path, storageID: storageID)
        guard !existing.contains(where: { !$0.isFolder && sameName($0.name, name) }) else {
            throw MTPError.alreadyExists(name: name, folder: display(path))
        }
        let size = try fileSize(localFile)
        if let storage = try link.storages().first(where: { $0.id == storageID }),
           size + spaceMargin > storage.freeBytes {
            throw MTPError.notEnoughSpace(needed: size, free: storage.freeBytes)
        }

        var cancelled = false
        let watched: ((UInt64, UInt64) -> Bool)? = progress.map { handler in
            { sent, total in
                let goOn = handler(sent, total)
                if !goOn { cancelled = true }
                return goOn
            }
        }
        let status: Int32
        do {
            status = try link.send(localFile: localFile, size: size, to: path, as: name, storageID: storageID, progress: watched)
        } catch {
            removeLeftover(link, named: name, in: path, storageID: storageID)
            throw error
        }

        // From here on, a file under `name` is ours: the name was free before the send.
        let remote = try link.entries(in: path, storageID: storageID).first { !$0.isFolder && sameName($0.name, name) }
        if cancelled {
            if let remote { _ = link.deleteObject(remote.id) }
            throw MTPError.cancelled
        }
        guard let remote else {
            throw MTPError.operationFailed(link.lastError(fallback: "\(name) is not on the device (libmtp status \(status))"))
        }
        guard remote.size == size else {
            _ = link.deleteObject(remote.id)
            throw MTPError.operationFailed(
                "Only \(remote.size) of \(size) bytes of \(name) reached the device, so the partial file was removed."
            )
        }
        guard size <= byteCompareLimit else { return }

        let readback = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: readback) }
        let matches: Bool
        do {
            try link.download(entryID: remote.id, to: readback)
            matches = try Data(contentsOf: readback) == Data(contentsOf: localFile)
        } catch {
            _ = link.deleteObject(remote.id)
            throw MTPError.operationFailed("\(name) could not be read back to check it, so it was removed. \(error.localizedDescription)")
        }
        guard matches else {
            _ = link.deleteObject(remote.id)
            throw MTPError.operationFailed("\(name) on the device differs from the local file, so it was removed.")
        }
    }

    /// Replaces the file `name` in `path` with a local file, so that a checked copy of either the old or the new
    /// file is on the device at every step:
    /// 1. the new file is uploaded and checked under a temporary name;
    /// 2. the old file is deleted;
    /// 3. the new file is uploaded and checked under `name`;
    /// 4. the temporary copy is deleted.
    /// MTP renames are not used, because devices differ in whether they allow them. Uploads twice, which suits
    /// small files such as courses. Without an old file this is a plain upload.
    public static func replace(_ link: MTPLink, localFile: URL, in path: [String], named name: String, storageID: UInt32) throws {
        guard let old = try link.entries(in: path, storageID: storageID).first(where: { !$0.isFolder && sameName($0.name, name) }) else {
            try upload(link, localFile: localFile, to: path, as: name, storageID: storageID)
            return
        }
        let temporary = temporaryName(for: name)
        try upload(link, localFile: localFile, to: path, as: temporary, storageID: storageID)
        let staged = try link.entries(in: path, storageID: storageID).first { !$0.isFolder && sameName($0.name, temporary) }

        do {
            try delete(link, entryID: old.id, named: name, in: path, storageID: storageID)
        } catch {
            if let staged { _ = link.deleteObject(staged.id) }
            throw error
        }
        do {
            try upload(link, localFile: localFile, to: path, as: name, storageID: storageID)
        } catch {
            throw MTPError.operationFailed(
                "The old \(name) was deleted, but the new one could not be written under its name. "
                    + "The new course is on the device as \(temporary). \(error.localizedDescription)"
            )
        }
        if let staged { _ = link.deleteObject(staged.id) }
    }

    /// Deletes one file from `path`, then checks that it is gone.
    public static func delete(_ link: MTPLink, entryID: UInt32, named name: String, in path: [String], storageID: UInt32) throws {
        let status = link.deleteObject(entryID)
        let remaining = try link.entries(in: path, storageID: storageID)
        guard !remaining.contains(where: { $0.id == entryID }) else {
            throw MTPError.operationFailed(link.lastError(fallback: "\(name) is still on the device (libmtp status \(status))"))
        }
    }

    /// Whether two file names are the same on the device, whose storage ignores case.
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The name a replacement is staged under. It does not end in `.fit`, so the Edge does not list it as a course.
    static func temporaryName(for name: String) -> String {
        "\(name).\(UUID().uuidString.prefix(8)).tmp"
    }

    private static func removeLeftover(_ link: MTPLink, named name: String, in path: [String], storageID: UInt32) {
        guard let entries = try? link.entries(in: path, storageID: storageID),
              let leftover = entries.first(where: { !$0.isFolder && sameName($0.name, name) }) else { return }
        _ = link.deleteObject(leftover.id)
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func display(_ path: [String]) -> String {
        "/" + path.joined(separator: "/")
    }
}
