import CLibMTP
import Foundation

public enum MTPError: Error, Equatable {
    case noDeviceAttached
    case detectFailed(code: UInt32)
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
public final class MTPConnection: MTPLink {
    private static let rootFolder: UInt32 = 0xFFFF_FFFF

    private let device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
    public let identity: MTPDeviceIdentity

    private init(device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, identity: MTPDeviceIdentity) {
        self.device = device
        self.identity = identity
    }

    deinit {
        LIBMTP_Release_Device(device)
    }

    /// Opens the first MTP device attached over USB.
    public static func openFirstDevice() throws -> MTPConnection {
        LIBMTP_Init()
        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
        if status == LIBMTP_ERROR_NO_DEVICE_ATTACHED {
            throw MTPError.noDeviceAttached
        }
        guard status == LIBMTP_ERROR_NONE, let rawDevices, count > 0 else {
            throw MTPError.detectFailed(code: status.rawValue)
        }
        // Copy the descriptor strings out before the raw device list is freed.
        let entry = rawDevices.pointee.device_entry
        let identity = MTPDeviceIdentity(
            vendor: entry.vendor.map { String(cString: $0) } ?? "",
            product: entry.product.map { String(cString: $0) } ?? "",
            vendorID: entry.vendor_id,
            productID: entry.product_id
        )
        defer { free(rawDevices) }

        guard let device = LIBMTP_Open_Raw_Device_Uncached(rawDevices) else {
            throw MTPError.openFailed
        }
        return MTPConnection(device: device, identity: identity)
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
        let folder = try folderID(for: path, storageID: storageID)
        return try children(of: folder, storageID: storageID)
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
        let parent = try folderID(for: path, storageID: storageID)
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
        LIBMTP_Delete_Object(device, id)
    }

    /// Copies one file from the device to a local path.
    public func download(entryID: UInt32, to localFile: URL) throws {
        let status = LIBMTP_Get_File_To_File(device, entryID, localFile.path, nil, nil)
        guard status == 0 else {
            throw MTPError.operationFailed(lastError(fallback: "download failed with code \(status)"))
        }
    }

    private func folderID(for path: [String], storageID: UInt32) throws -> UInt32 {
        var parent = Self.rootFolder
        for name in path {
            let folder = try children(of: parent, storageID: storageID)
                .first { $0.isFolder && $0.name == name }
            guard let folder else {
                throw MTPError.folderNotFound("/" + path.joined(separator: "/"))
            }
            parent = folder.id
        }
        return parent
    }

    private func children(of parent: UInt32, storageID: UInt32) throws -> [MTPEntry] {
        // libmtp returns NULL for an empty folder, so NULL means no children here.
        guard let head = LIBMTP_Get_Files_And_Folders(device, storageID, parent) else {
            return []
        }

        var entries: [MTPEntry] = []
        var cursor: UnsafeMutablePointer<LIBMTP_file_t>? = head
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
