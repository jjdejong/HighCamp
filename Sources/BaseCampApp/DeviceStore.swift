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
    /// The device's courses, activities and GPX files, read after it connects.
    var contents = DeviceContents()
    /// Where copies of the device's files are kept, so a device connected again only has new files read. Set by
    /// the main view; nothing is read from the device without it.
    var cacheFolder: URL?
    private var contentsTask: Task<Void, Never>?
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
                if case .connected(let name, _) = result {
                    loadContents(deviceName: name)
                } else {
                    contentsTask?.cancel()
                    contents = DeviceContents()
                }
            }
        }
    }

    /// Reads the device's courses, activities and GPX files, one file at a time so a send can go between two, and
    /// publishes what is read as it goes. A file already copied, with the same name and size, is read from the copy.
    private func loadContents(deviceName: String) {
        guard let cacheFolder else { return }
        contentsTask?.cancel()
        let device = device
        let folder = cacheFolder.appendingPathComponent(deviceName)
        contentsTask = Task {
            let listed: [(kind: DeviceGroup.Kind, files: [MTPEntry])]
            do {
                listed = try await device.perform { link, storage in
                    DeviceGroup.Kind.allCases.map { kind in
                        // A device without the folder (no GPX files, say) has nothing of that kind.
                        let entries = (try? link.entries(in: kind.folder, storageID: storage.id)) ?? []
                        let files = entries
                            .filter { !$0.isFolder && ($0.name as NSString).pathExtension.lowercased() == kind.fileExtension }
                            .sorted { kind == .activities ? $0.name > $1.name : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        return (kind, files)
                    }
                }
            } catch {
                return
            }
            var groups = listed.map { DeviceGroup(kind: $0.kind) }
            let total = listed.reduce(0) { $0 + $1.files.count }
            var done = 0
            contents = DeviceContents(deviceName: deviceName, groups: groups, progress: (0, total))
            for (index, entry) in listed.enumerated() {
                let local = folder.appendingPathComponent(entry.kind.rawValue)
                try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                Self.removeCopies(in: local, except: Set(entry.files.map(\.name)))
                for file in entry.files {
                    guard !Task.isCancelled else { return }
                    let copy = local.appendingPathComponent(file.name)
                    if Self.size(of: copy) != file.size {
                        do {
                            try await device.perform { link, _ in try link.download(entryID: file.id, to: copy) }
                        } catch {
                            try? FileManager.default.removeItem(at: copy)
                            done += 1
                            continue
                        }
                    }
                    let kind = entry.kind
                    let items = await Task.detached(priority: .utility) {
                        (try? Data(contentsOf: copy)).map { DeviceFileReader.items(in: $0, file: file.name, kind: kind) } ?? Library()
                    }.value
                    groups[index].library.waypoints += items.waypoints
                    groups[index].library.routes += items.routes
                    groups[index].library.tracks += items.tracks
                    for item in DeviceGroup(kind: kind, library: items).items {
                        groups[index].files[item] = file.name
                    }
                    done += 1
                    // Published every few files, so the sidebar fills in without redrawing for each one.
                    if done % 8 == 0 || done == total {
                        contents = DeviceContents(deviceName: deviceName, groups: groups, progress: done == total ? nil : (done, total))
                    }
                }
            }
            // By the names shown, as the library is listed; activities newest first.
            for index in groups.indices {
                let byName = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
                groups[index].library.waypoints.sort { byName($0.name, $1.name) }
                groups[index].library.routes.sort { byName($0.name, $1.name) }
                if groups[index].kind == .activities {
                    groups[index].library.tracks.sort { ($0.segments.first?.first?.time ?? .distantPast) > ($1.segments.first?.first?.time ?? .distantPast) }
                } else {
                    groups[index].library.tracks.sort { byName($0.name, $1.name) }
                }
            }
            contents = DeviceContents(deviceName: deviceName, groups: groups, progress: nil)
        }
    }

    /// Deletes files from the device, checking each is gone, then reads the device's contents again. Stops at the
    /// first file that cannot be deleted; those before it stay deleted.
    func deleteFiles(_ files: [DeviceFileRef]) async throws {
        guard isConnected, mapTransfer == nil, !files.isEmpty else { return }
        defer { refresh() }
        let device = device
        try await device.perform { link, storage in
            for file in files {
                let entries = try link.entries(in: file.kind.folder, storageID: storage.id)
                guard let entry = entries.first(where: { !$0.isFolder && $0.name == file.name }) else { continue }
                try MTPTransfers.delete(link, entryID: entry.id, named: entry.name, in: file.kind.folder, storageID: storage.id)
            }
        }
    }

    nonisolated private static func size(of file: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value
    }

    /// Removes the copies of files that are no longer on the device.
    nonisolated private static func removeCopies(in folder: URL, except names: Set<String>) {
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in copies where !names.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
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
