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

/// A course waiting for the user to confirm that it replaces the one on the device with the same file name.
struct PendingCourse: Equatable {
    let name: String
    let fileName: String
    let points: [CoursePoint]
}

/// Looks for an MTP device, reports what it finds, sends courses to it and reads activities from it.
/// All device work goes through one `MTPDevice`, so only one libmtp connection exists and nothing overlaps.
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
    /// A course with the same file name is already on the device; the user is asked whether to replace it.
    var pendingReplacement: PendingCourse?
    /// The map being copied to the device, if any.
    var mapTransfer: MapTransfer?
    private var transferMonitor: TransferMonitor?
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let device = MTPDevice()

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
        let device = device
        refreshTask = Task {
            let result: DeviceState
            do {
                let status = try await device.status()
                result = .connected(name: DeviceStore.displayName(for: status.identity), storages: status.storages)
            } catch MTPError.noDeviceAttached {
                result = .disconnected
            } catch {
                result = .failed(error.localizedDescription)
            }
            if !Task.isCancelled {
                state = result
            }
        }
    }

    /// Encodes the points as a FIT course and uploads it to Garmin/Courses. The upload is read back from the
    /// device before the send is reported as a success. When a course with the same file name is there, nothing
    /// is sent and `pendingReplacement` asks the user first; `replace` sends it in place of the old one.
    func sendCourse(name: String, points: [CoursePoint]) {
        send(PendingCourse(name: name, fileName: FITCourse.fileName(for: name), points: points), replacing: false)
    }

    func replace(_ course: PendingCourse) {
        pendingReplacement = nil
        send(course, replacing: true)
    }

    private func send(_ course: PendingCourse, replacing: Bool) {
        guard isConnected, !isSending, mapTransfer == nil else { return }
        isSending = true
        let device = device
        Task {
            defer { isSending = false }
            do {
                let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: localFile) }
                try FITCourse.encode(name: course.name, points: course.points).write(to: localFile)
                try await device.perform { link, storage in
                    if replacing {
                        try MTPTransfers.replace(link, localFile: localFile, in: DeviceStore.coursesFolder, named: course.fileName, storageID: storage.id)
                    } else {
                        try MTPTransfers.upload(link, localFile: localFile, to: DeviceStore.coursesFolder, as: course.fileName, storageID: storage.id)
                    }
                }
                sendMessage = replacing
                    ? "Replaced \(course.fileName) in Garmin/Courses and checked it on the device."
                    : "Sent \(course.fileName) to Garmin/Courses and checked it on the device."
            } catch MTPError.alreadyExists where !replacing {
                pendingReplacement = course
            } catch {
                sendMessage = "Could not send \(course.fileName). \(error.localizedDescription)"
            }
        }
    }

    /// Every map on the device, sorted by name. Lists names and sizes only.
    func deviceMaps() async throws -> [DeviceMap] {
        try await device.perform { link, storage in
            let files = try link.entries(in: DeviceStore.mapsFolder, storageID: storage.id).filter { !$0.isFolder }
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
    }

    /// Copies a map from disk to the device, with progress. Refreshes the device status when done. The free space
    /// is checked on the device first, and a partial or cancelled copy is removed.
    func sendMap(_ map: MapFile) async throws {
        guard isConnected, mapTransfer == nil else { return }
        let monitor = TransferMonitor()
        transferMonitor = monitor
        mapTransfer = MapTransfer(name: map.name, fraction: 0)
        defer {
            mapTransfer = nil
            transferMonitor = nil
            refresh()
        }
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor [weak self] in
                self?.mapTransfer?.fraction = fraction
            }
        }
        try await device.perform { link, storage in
            try MTPTransfers.upload(
                link, localFile: map.url, to: DeviceStore.mapsFolder, as: map.url.lastPathComponent, storageID: storage.id
            ) { sent, total in
                let fraction = total == 0 ? 1 : Double(sent) / Double(total)
                if monitor.shouldReport(fraction) {
                    report(fraction)
                }
                return !monitor.isCancelled
            }
        }
    }

    func cancelMapTransfer() {
        transferMonitor?.cancel()
    }

    /// Deletes a custom map from the device. Built-in and licensed maps are never deleted.
    func deleteMap(_ map: DeviceMap) async throws {
        guard map.kind.canDelete, mapTransfer == nil else { return }
        try await device.perform { link, storage in
            try MTPTransfers.delete(link, entryID: map.file.id, named: map.file.name, in: DeviceStore.mapsFolder, storageID: storage.id)
        }
        refresh()
    }

    /// The activity files in Garmin/Activities, newest first.
    func activities() async throws -> [DeviceFile] {
        try await device.perform { link, storage in
            try link.entries(in: DeviceStore.activitiesFolder, storageID: storage.id)
                .filter { !$0.isFolder }
                .map { DeviceFile(id: $0.id, name: $0.name, size: $0.size) }
                .sorted { $0.name > $1.name }
        }
    }

    /// Copies one activity from the device and reads its GPS track.
    func track(for file: DeviceFile) async throws -> Track {
        let data = try await device.perform { link, _ in
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: localFile) }
            try link.download(entryID: file.id, to: localFile)
            return try Data(contentsOf: localFile)
        }
        return try FITActivity.read(data, name: (file.name as NSString).deletingPathExtension)
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
        case .alreadyExists(let name, let folder):
            "\(name) is already in \(folder) on the device."
        case .notEnoughSpace(let needed, let free):
            "The device has \(Format.bytes(free)) free, and \(Format.bytes(needed)) plus 1 MB to spare is needed."
        case .cancelled:
            "The copy was cancelled, and the partial file was removed from the device."
        }
    }
}

extension FITCourseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooFewPoints:
            "A course needs at least two points."
        case .invalidSpeed:
            "The course speed must be more than zero."
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
