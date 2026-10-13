import BaseCampCore
import BaseCampMTP
import Foundation
import Observation

/// What the status bar shows about the Garmin device.
enum DeviceState: Equatable {
    case searching
    case disconnected
    case connected(name: String, storages: [MTPStorage])
    case failed(String)
}

/// A file on the device, such as an activity.
struct DeviceFile: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let size: UInt64
}

/// Looks for an MTP device, reports what it finds, sends courses to it and reads activities from it.
@MainActor
@Observable
final class DeviceStore {
    nonisolated static let coursesFolder = ["Garmin", "Courses"]
    nonisolated static let activitiesFolder = ["Garmin", "Activities"]
    /// Garmin keeps its map files (`.img`) directly in this folder.
    nonisolated static let mapsFolder = ["Garmin"]

    var state: DeviceState = .searching
    var isSending = false
    /// Outcome of the last send, shown in an alert until dismissed.
    var sendMessage: String?
    /// The map being copied to the device, if any.
    var mapTransfer: MapTransfer?
    private var transferMonitor: TransferMonitor?
    private var refreshTask: Task<Void, Never>?

    /// Free space on the device's first storage, if known.
    var freeBytes: UInt64? {
        if case .connected(_, let storages) = state {
            return storages.first?.freeBytes
        }
        return nil
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func refresh() {
        refreshTask?.cancel()
        state = .searching
        refreshTask = Task {
            // libmtp blocks, so the USB work runs off the main actor.
            let result = await Task.detached { DeviceStore.probe() }.value
            if !Task.isCancelled {
                state = result
            }
        }
    }

    /// Encodes the points as a FIT course and uploads it to Garmin/Courses. The upload is read back
    /// from the device before the send is reported as a success.
    func sendCourse(name: String, points: [CoursePoint]) {
        guard isConnected, !isSending, mapTransfer == nil else { return }
        isSending = true
        Task {
            let result = await Task.detached { DeviceStore.upload(name: name, points: points) }.value
            isSending = false
            sendMessage = result
        }
    }

    /// Every map on the device, sorted by name. Lists names and sizes only.
    func deviceMaps() async throws -> [DeviceMap] {
        try await Task.detached { try DeviceStore.listMaps() }.value
    }

    /// Copies a map from disk to the device, with progress. Refreshes the device status when done.
    func sendMap(_ map: MapFile) async throws {
        guard isConnected, mapTransfer == nil else { return }
        let monitor = TransferMonitor()
        transferMonitor = monitor
        mapTransfer = MapTransfer(name: map.name, fraction: 0)
        defer {
            mapTransfer = nil
            transferMonitor = nil
        }
        try await Task.detached {
            try DeviceStore.uploadMap(map.url, monitor: monitor) { fraction in
                Task { @MainActor [weak self] in
                    self?.mapTransfer?.fraction = fraction
                }
            }
        }.value
        refresh()
    }

    func cancelMapTransfer() {
        transferMonitor?.cancel()
    }

    /// Deletes a custom map from the device. Built-in and licensed maps are never deleted.
    func deleteMap(_ map: DeviceMap) async throws {
        guard map.kind.canDelete, mapTransfer == nil else { return }
        try await Task.detached {
            try DeviceStore.removeFile(map.file, from: DeviceStore.mapsFolder)
        }.value
        refresh()
    }

    /// The activity files in Garmin/Activities, newest first.
    func activities() async throws -> [DeviceFile] {
        try await Task.detached { try DeviceStore.listFiles(in: DeviceStore.activitiesFolder) }.value
    }

    /// Copies one activity from the device and reads its GPS track.
    func track(for file: DeviceFile) async throws -> Track {
        try await Task.detached { try DeviceStore.readTrack(from: file) }.value
    }

    nonisolated static func probe() -> DeviceState {
        do {
            let connection = try MTPConnection.openFirstDevice()
            let storages = try connection.storages()
            return .connected(name: displayName(for: connection.identity), storages: storages)
        } catch MTPError.noDeviceAttached {
            return .disconnected
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func upload(name: String, points: [CoursePoint]) -> String {
        let fileName = FITCourse.fileName(for: name)
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localFile) }

        do {
            try FITCourse.encode(name: name, points: points).write(to: localFile)
            let connection = try MTPConnection.openFirstDevice()
            guard let storage = try connection.storages().first else {
                return "The device reports no storage."
            }
            try connection.upload(
                localFile: localFile,
                to: coursesFolder,
                as: fileName,
                storageID: storage.id
            )
            return "Sent \(fileName) to Garmin/Courses and checked it on the device."
        } catch {
            return "Could not send \(fileName). \(error.localizedDescription)"
        }
    }

    nonisolated static func listFiles(in folder: [String]) throws -> [DeviceFile] {
        let connection = try MTPConnection.openFirstDevice()
        guard let storage = try connection.storages().first else {
            return []
        }
        return try connection.entries(in: folder, storageID: storage.id)
            .filter { !$0.isFolder }
            .map { DeviceFile(id: $0.id, name: $0.name, size: $0.size) }
            .sorted { $0.name > $1.name }
    }

    nonisolated static func listMaps() throws -> [DeviceMap] {
        let connection = try MTPConnection.openFirstDevice()
        guard let storage = try connection.storages().first else {
            return []
        }
        let files = try connection.entries(in: mapsFolder, storageID: storage.id)
            .filter { !$0.isFolder }
        let names = Set(files.map { $0.name.lowercased() })
        return files
            .filter { $0.name.lowercased().hasSuffix(".img") }
            .map { entry in
                DeviceMap(
                    file: DeviceFile(id: entry.id, name: entry.name, size: entry.size),
                    kind: DeviceMapKind.classify(name: entry.name, siblings: names)
                )
            }
            .sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    nonisolated static func uploadMap(
        _ localFile: URL,
        monitor: TransferMonitor,
        report: @escaping @Sendable (Double) -> Void
    ) throws {
        let connection = try MTPConnection.openFirstDevice()
        guard let storage = try connection.storages().first else {
            throw MTPError.operationFailed("The device reports no storage.")
        }
        try connection.upload(
            localFile: localFile,
            to: mapsFolder,
            as: localFile.lastPathComponent,
            storageID: storage.id
        ) { sent, total in
            let fraction = total == 0 ? 1 : Double(sent) / Double(total)
            if monitor.shouldReport(fraction) {
                report(fraction)
            }
            return !monitor.isCancelled
        }
    }

    nonisolated static func removeFile(_ file: DeviceFile, from folder: [String]) throws {
        let connection = try MTPConnection.openFirstDevice()
        guard let storage = try connection.storages().first else {
            throw MTPError.operationFailed("The device reports no storage.")
        }
        try connection.delete(entryID: file.id, named: file.name, in: folder, storageID: storage.id)
    }

    nonisolated static func readTrack(from file: DeviceFile) throws -> Track {
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localFile) }

        let connection = try MTPConnection.openFirstDevice()
        try connection.download(entryID: file.id, to: localFile)
        let data = try Data(contentsOf: localFile)
        let stem = (file.name as NSString).deletingPathExtension
        return try FITActivity.read(data, name: stem)
    }

    nonisolated static func displayName(for identity: MTPDeviceIdentity) -> String {
        let parts = [identity.vendor, identity.product].filter { !$0.isEmpty }
        if parts.isEmpty {
            return String(format: "MTP device %04X:%04X", identity.vendorID, identity.productID)
        }
        return parts.joined(separator: " ")
    }
}

extension MTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDeviceAttached:
            "No MTP device is attached over USB."
        case .detectFailed(let code):
            "The USB scan failed (libmtp code \(code))."
        case .openFailed:
            "The device was found but could not be opened. Unplug and replug it."
        case .folderNotFound(let path):
            "The folder \(path) is not on the device."
        case .operationFailed(let detail):
            detail
        }
    }
}

extension FITCourseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooFewPoints:
            "A course needs at least two points."
        }
    }
}

extension FITReadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFITFile:
            "The file is not a FIT file."
        case .truncated:
            "The FIT file ends before its last message."
        case .undefinedMessage(let localType):
            "The FIT file uses message type \(localType) before defining it."
        }
    }
}
