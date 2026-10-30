import CLibMTP
import Foundation

public enum MTPError: Error, Equatable {
    case noDeviceAttached
    case openFailed
    case folderNotFound(String)
    case operationFailed(String)
    case alreadyExists(name: String, folder: String)
    case notEnoughSpace(needed: UInt64, free: UInt64)
    case cancelled
}

/// What the USB descriptor says about the device, read before the connection is opened.
public struct MTPDeviceIdentity: Equatable, Sendable {
    public let vendor: String
    public let product: String
    public let vendorID: UInt16
    public let productID: UInt16
}

public struct MTPStorage: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let freeBytes: UInt64
    public let capacityBytes: UInt64
}

public struct MTPEntry: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let size: UInt64
    public let isFolder: Bool
}

/// A connection to one MTP device, wrapping libmtp.
///
/// libmtp is not thread-safe. Use one connection from one thread at a time.
///
/// Folders are found by walking down from the top of a storage, with each folder's listing kept for the next walk,
/// so that reading many files in one folder does not list every folder above it each time. Listing a folder asks
/// the device for that folder itself; only the folders above it come from memory. A walk that fails forgets every
/// listing and is tried once more, as another app may have changed the device; so does a download that fails.
/// Names are matched ignoring case, as on the device's FAT storage. The QMapShack libmtp access on macOS
/// (`CDeviceAccessLibMtp`, by the same author) does the same.
public final class MTPConnection: MTPLink {
    private static let rootFolder: UInt32 = 0xFFFF_FFFF

    private let device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
    public let identity: MTPDeviceIdentity
    /// The latest listing of each folder, by storage and lower-cased path ("" for the top).
    private var listings: [ListingKey: [MTPEntry]] = [:]

    private struct ListingKey: Hashable {
        let storage: UInt32
        let path: String

        init(_ storage: UInt32, _ path: some Sequence<String>) {
            self.storage = storage
            self.path = path.map { $0.lowercased() }.joined(separator: "/")
        }
    }

    private init(device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, identity: MTPDeviceIdentity) {
        self.device = device
        self.identity = identity
    }

    deinit {
        LIBMTP_Release_Device(device)
    }

    private static let initialized: Void = LIBMTP_Init()

    /// Opens the MTP device plugged in at `usb`, and no other. Its flags come from libmtp's table of devices; a
    /// device missing from the table is first asked whether it speaks MTP at all.
    public static func open(_ usb: USBDeviceAddress) throws -> MTPConnection {
        _ = initialized
        var raw = LIBMTP_raw_device_t()
        raw.bus_location = UInt32(usb.bus)
        raw.devnum = usb.address
        raw.device_entry.vendor_id = usb.vendorID
        raw.device_entry.product_id = usb.productID
        var table: UnsafeMutablePointer<LIBMTP_device_entry_t>?
        var count: Int32 = 0
        var known: LIBMTP_device_entry_t?
        if LIBMTP_Get_Supported_Devices_List(&table, &count) == 0, let table {
            known = UnsafeBufferPointer(start: table, count: Int(count))
                .first { $0.vendor_id == usb.vendorID && $0.product_id == usb.productID }
        }
        if let known {
            raw.device_entry = known
        } else if LIBMTP_Check_Specific_Device(Int32(usb.bus), Int32(usb.address)) == 0 {
            throw MTPError.openFailed
        }
        guard let device = LIBMTP_Open_Raw_Device_Uncached(&raw) else {
            throw MTPError.openFailed
        }
        // A device still starting up reports no storage yet.
        guard device.pointee.storage != nil else {
            LIBMTP_Release_Device(device)
            throw MTPError.openFailed
        }
        let identity = MTPDeviceIdentity(
            vendor: known?.vendor.map { String(cString: $0) } ?? owned(LIBMTP_Get_Manufacturername(device)),
            product: known?.product.map { String(cString: $0) } ?? owned(LIBMTP_Get_Modelname(device)),
            vendorID: usb.vendorID,
            productID: usb.productID
        )
        return MTPConnection(device: device, identity: identity)
    }

    /// Opens the first Garmin device plugged in, for the command-line tools.
    public static func openFirstGarmin() throws -> MTPConnection {
        guard let usb = GarminUSB.devices().first else {
            throw MTPError.noDeviceAttached
        }
        return try open(usb)
    }

    /// A string libmtp allocated for the caller, freed.
    private static func owned(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Storage areas on the device, such as internal memory and an SD card.
    public func storages() throws -> [MTPStorage] {
        guard LIBMTP_Get_Storage(device, 0) == 0 else {
            throw MTPError.operationFailed(lastError(fallback: "could not read storage list"))
        }

        var result: [MTPStorage] = []
        var cursor = device.pointee.storage
        while let storage = cursor {
            result.append(MTPStorage(
                id: storage.pointee.id,
                name: string(storage.pointee.StorageDescription) ?? "Storage",
                freeBytes: storage.pointee.FreeSpaceInBytes,
                capacityBytes: storage.pointee.MaxCapacity
            ))
            cursor = storage.pointee.next
        }
        return result
    }

    /// Lists the files and folders inside `path`, for example `["Garmin", "NewFiles"]`.
    public func entries(in path: [String], storageID: UInt32) throws -> [MTPEntry] {
        try retryingWalk {
            let folder = try folderID(for: path, storageID: storageID)
            return try listing(of: folder, at: path, storageID: storageID, fresh: true)
        }
    }

    /// Sends a local file into `path` under `name`, checks it on the device, and removes anything partial.
    /// See `MTPTransfers.upload`.
    public func upload(
        localFile: URL,
        to path: [String],
        as name: String,
        storageID: UInt32,
        progress: ((UInt64, UInt64) -> Bool)? = nil
    ) throws {
        try MTPTransfers.upload(self, localFile: localFile, to: path, as: name, storageID: storageID, progress: progress)
    }

    /// Deletes one file from `path` on one storage, then checks that it is gone.
    public func delete(entryID: UInt32, named name: String, in path: [String], storageID: UInt32) throws {
        try MTPTransfers.delete(self, entryID: entryID, named: name, in: path, storageID: storageID)
    }

    public func send(
        localFile: URL, size: UInt64, to path: [String], as name: String, storageID: UInt32,
        progress: ((UInt64, UInt64) -> Bool)?
    ) throws -> Int32 {
        let parent = try retryingWalk { try folderID(for: path, storageID: storageID) }
        // The folder's listing changes, whatever the outcome.
        defer { listings[ListingKey(storageID, path)] = nil }
        guard let file = LIBMTP_new_file_t() else {
            throw MTPError.operationFailed("could not allocate a file record")
        }
        defer { LIBMTP_destroy_file_t(file) }
        file.pointee.parent_id = parent
        file.pointee.storage_id = storageID
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.filesize = size
        file.pointee.filename = strdup(name)

        guard let progress else {
            return LIBMTP_Send_File_From_File(device, localFile.path, file, nil, nil)
        }
        let box = ProgressBox(handler: progress)
        return withExtendedLifetime(box) {
            LIBMTP_Send_File_From_File(
                device, localFile.path, file, mtpProgressCallback,
                UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque())
            )
        }
    }

    public func deleteObject(_ id: UInt32) -> Int32 {
        // The listings that held the object change, whatever the outcome.
        for (key, entries) in listings where entries.contains(where: { $0.id == id }) {
            listings[key] = nil
        }
        return LIBMTP_Delete_Object(device, id)
    }

    /// Copies one file from the device to a local path.
    public func download(entryID: UInt32, to localFile: URL) throws {
        let status = LIBMTP_Get_File_To_File(device, entryID, localFile.path, nil, nil)
        guard status == 0 else {
            // The id may be stale: the device may have changed since it was listed.
            listings.removeAll()
            throw MTPError.operationFailed(lastError(fallback: "download failed with code \(status)"))
        }
    }

    /// Runs a walk, and once more with nothing remembered if it fails: a remembered listing may hold the id of a
    /// folder another app has removed or made anew since.
    private func retryingWalk<T>(_ walk: () throws -> T) throws -> T {
        do {
            return try walk()
        } catch {
            listings.removeAll()
            return try walk()
        }
    }

    /// The folder at `path`, walking down with the listings remembered for the folders above it.
    private func folderID(for path: [String], storageID: UInt32) throws -> UInt32 {
        var parent = Self.rootFolder
        for (depth, name) in path.enumerated() {
            let folder = try listing(of: parent, at: path.prefix(depth), storageID: storageID, fresh: false)
                .first { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard let folder else {
                throw MTPError.folderNotFound("/" + path.joined(separator: "/"))
            }
            parent = folder.id
        }
        return parent
    }

    /// A folder's listing, from memory unless `fresh`, else from the device and remembered.
    private func listing(of folder: UInt32, at path: some Sequence<String>, storageID: UInt32, fresh: Bool) throws -> [MTPEntry] {
        let key = ListingKey(storageID, path)
        if !fresh, let remembered = listings[key] {
            return remembered
        }
        listings[key] = nil
        let entries = try children(of: folder, storageID: storageID)
        listings[key] = entries
        return entries
    }

    private func children(of parent: UInt32, storageID: UInt32) throws -> [MTPEntry] {
        LIBMTP_Clear_Errorstack(device)
        var entries: [MTPEntry] = []
        var cursor = LIBMTP_Get_Files_And_Folders(device, storageID, parent)
        while let file = cursor {
            entries.append(MTPEntry(
                id: file.pointee.item_id,
                name: string(file.pointee.filename) ?? "",
                size: file.pointee.filesize,
                isFolder: file.pointee.filetype == LIBMTP_FILETYPE_FOLDER
            ))
            cursor = file.pointee.next
            LIBMTP_destroy_file_t(file)
        }
        // libmtp returns no files for an empty folder and for a failed listing alike; only the error stack tells.
        if LIBMTP_Get_Errorstack(device) != nil {
            throw MTPError.operationFailed(lastError(fallback: "the folder could not be listed"))
        }
        return entries
    }

    public func lastError(fallback: String) -> String {
        guard let stack = LIBMTP_Get_Errorstack(device) else {
            return fallback
        }
        defer { LIBMTP_Clear_Errorstack(device) }

        var messages: [String] = []
        var cursor: UnsafeMutablePointer<LIBMTP_error_t>? = stack
        while let error = cursor {
            if let text = string(error.pointee.error_text) {
                messages.append(text)
            }
            cursor = error.pointee.next
        }
        return messages.isEmpty ? fallback : messages.joined(separator: "; ")
    }

    private func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }
}

/// Carries a Swift progress handler through libmtp's C callback.
private final class ProgressBox {
    let handler: (UInt64, UInt64) -> Bool

    init(handler: @escaping (UInt64, UInt64) -> Bool) {
        self.handler = handler
    }
}

/// libmtp treats a non-zero return from this callback as a request to cancel the transfer.
private let mtpProgressCallback: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    return box.handler(sent, total) ? 0 : 1
}
