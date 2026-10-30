@testable import BaseCampMTP
import XCTest

/// A device in memory: one storage, folders by path, and send faults like the ones Edge devices show.
final class FakeLink: MTPLink, @unchecked Sendable {
    enum SendFault {
        case none
        /// Writes the file but reports an error, as Edge devices sometimes do.
        case errorStatusButWritten
        /// Writes only the first half of the file.
        case truncated
        /// Writes the whole length with different bytes.
        case corrupted
        /// Writes nothing.
        case nothing
        /// Throws after writing half of the file.
        case throwsAfterHalf
    }

    struct File {
        var id: UInt32
        var name: String
        var data: Data
    }

    let identity = MTPDeviceIdentity(vendor: "Garmin", product: "Fake Edge", vendorID: 0x091E, productID: 0)
    var free: UInt64 = 1 << 30
    var folders: [[String]: [File]] = [["Garmin", "Courses"]: [], ["Garmin"]: []]
    var faults: [SendFault] = []
    var failNextDelete = false
    var failStorages = false
    private var nextID: UInt32 = 100
    private(set) var sentNames: [String] = []

    private let lock = NSLock()
    private var running = 0
    private(set) var maximumRunning = 0

    /// Marks one operation as running, to check that the device actor never overlaps them.
    private func enter() {
        lock.lock()
        running += 1
        maximumRunning = max(maximumRunning, running)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.002)
        lock.lock()
        running -= 1
        lock.unlock()
    }

    func add(_ name: String, data: Data, in path: [String]) {
        nextID += 1
        folders[path, default: []].append(File(id: nextID, name: name, data: data))
    }

    func file(_ name: String, in path: [String]) -> File? {
        folders[path]?.first { $0.name == name }
    }

    private(set) var storageReads = 0

    func storages() throws -> [MTPStorage] {
        enter()
        storageReads += 1
        if failStorages { throw MTPError.operationFailed("USB gone") }
        return [MTPStorage(id: 1, name: "Internal", freeBytes: free, capacityBytes: 1 << 32)]
    }

    func entries(in path: [String], storageID: UInt32) throws -> [MTPEntry] {
        enter()
        guard let files = folders[path] else { throw MTPError.folderNotFound("/" + path.joined(separator: "/")) }
        return files.map { MTPEntry(id: $0.id, name: $0.name, size: UInt64($0.data.count), isFolder: false) }
    }

    func send(
        localFile: URL, size: UInt64, to path: [String], as name: String, storageID: UInt32,
        progress: ((UInt64, UInt64) -> Bool)?
    ) throws -> Int32 {
        enter()
        sentNames.append(name)
        let data = try Data(contentsOf: localFile)
        let fault = faults.isEmpty ? .none : faults.removeFirst()
        if let progress, !progress(size / 2, size) {
            add(name, data: data.prefix(data.count / 2), in: path)
            return -1
        }
        switch fault {
        case .none: add(name, data: data, in: path)
        case .errorStatusButWritten: add(name, data: data, in: path); return -1
        case .truncated: add(name, data: data.prefix(data.count / 2), in: path); return -1
        case .corrupted: add(name, data: Data(repeating: 0x55, count: data.count), in: path)
        case .nothing: return -1
        case .throwsAfterHalf:
            add(name, data: data.prefix(data.count / 2), in: path)
            throw MTPError.operationFailed("USB error")
        }
        _ = progress?(size, size)
        return 0
    }

    func deleteObject(_ id: UInt32) -> Int32 {
        enter()
        if failNextDelete {
            failNextDelete = false
            return -1
        }
        for path in folders.keys {
            folders[path]?.removeAll { $0.id == id }
        }
        return 0
    }

    func download(entryID: UInt32, to localFile: URL) throws {
        enter()
        guard let file = folders.values.joined().first(where: { $0.id == entryID }) else {
            throw MTPError.operationFailed("no object \(entryID)")
        }
        try file.data.write(to: localFile)
    }

    func lastError(fallback: String) -> String { fallback }
}

final class MTPTransfersTests: XCTestCase {
    private let courses = ["Garmin", "Courses"]
    private var local: URL!
    private let content = Data((0..<4000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fit")
        try content.write(to: local)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: local)
    }

    func testUploadWritesAndChecksTheFile() throws {
        let link = FakeLink()
        try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1)
        XCTAssertEqual(link.file("Ride.fit", in: courses)?.data, content)
    }

    func testAnErrorStatusWithACompleteFileIsASuccess() throws {
        let link = FakeLink()
        link.faults = [.errorStatusButWritten]
        try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1)
        XCTAssertEqual(link.file("Ride.fit", in: courses)?.data, content)
    }

    func testAPartialFileIsRemoved() {
        let link = FakeLink()
        link.faults = [.truncated]
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1))
        XCTAssertNil(link.file("Ride.fit", in: courses))
    }

    func testAFileWithWrongBytesIsRemoved() {
        let link = FakeLink()
        link.faults = [.corrupted]
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1))
        XCTAssertNil(link.file("Ride.fit", in: courses))
    }

    func testAPartialFileIsRemovedWhenTheSendThrows() {
        let link = FakeLink()
        link.faults = [.throwsAfterHalf]
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1))
        XCTAssertNil(link.file("Ride.fit", in: courses))
    }

    func testACancelledUploadIsRemoved() {
        let link = FakeLink()
        XCTAssertThrowsError(
            try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1) { _, _ in false }
        ) { XCTAssertEqual($0 as? MTPError, .cancelled) }
        XCTAssertNil(link.file("Ride.fit", in: courses))
    }

    func testAMissingFileIsReported() {
        let link = FakeLink()
        link.faults = [.nothing]
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1))
    }

    func testAnExistingFileIsNeitherSentNorTouched() {
        let link = FakeLink()
        link.add("Ride.fit", data: Data("old".utf8), in: courses)
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1)) {
            XCTAssertEqual($0 as? MTPError, .alreadyExists(name: "Ride.fit", folder: "/Garmin/Courses"))
        }
        XCTAssertEqual(link.file("Ride.fit", in: courses)?.data, Data("old".utf8))
        XCTAssertTrue(link.sentNames.isEmpty)
    }

    func testAnExistingFileIsFoundIgnoringCase() {
        let link = FakeLink()
        link.add("ride.FIT", data: Data("old".utf8), in: courses)
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1)) {
            XCTAssertEqual($0 as? MTPError, .alreadyExists(name: "Ride.fit", folder: "/Garmin/Courses"))
        }
        XCTAssertTrue(link.sentNames.isEmpty)
    }

    func testAFileThatDoesNotFitIsNotSent() {
        let link = FakeLink()
        link.free = MTPTransfers.spaceMargin + UInt64(content.count) - 1
        XCTAssertThrowsError(try MTPTransfers.upload(link, localFile: local, to: courses, as: "Ride.fit", storageID: 1)) {
            XCTAssertEqual($0 as? MTPError, .notEnoughSpace(needed: UInt64(self.content.count), free: link.free))
        }
        XCTAssertTrue(link.sentNames.isEmpty)
    }

    func testReplaceLeavesOnlyTheNewFile() throws {
        let link = FakeLink()
        link.add("Ride.fit", data: Data("old".utf8), in: courses)
        link.add("Other.fit", data: Data("keep".utf8), in: courses)
        try MTPTransfers.replace(link, localFile: local, in: courses, named: "Ride.fit", storageID: 1)
        XCTAssertEqual(link.file("Ride.fit", in: courses)?.data, content)
        XCTAssertEqual(link.file("Other.fit", in: courses)?.data, Data("keep".utf8))
        XCTAssertEqual(link.folders[courses]?.count, 2, "no temporary copy is left")
    }

    func testReplaceKeepsTheOldFileWhenTheNewOneFails() {
        let link = FakeLink()
        link.add("Ride.fit", data: Data("old".utf8), in: courses)
        link.faults = [.truncated]
        XCTAssertThrowsError(try MTPTransfers.replace(link, localFile: local, in: courses, named: "Ride.fit", storageID: 1))
        XCTAssertEqual(link.file("Ride.fit", in: courses)?.data, Data("old".utf8))
        XCTAssertEqual(link.folders[courses]?.count, 1)
    }

    func testReplaceKeepsTheOldFileWhenItCannotBeDeleted() {
        let link = FakeLink()
        link.add("Ride.fit", data: Data("old".utf8), in: courses)
        link.failNextDelete = true
        XCTAssertThrowsError(try MTPTransfers.replace(link, localFile: local, in: courses, named: "Ride.fit", storageID: 1))
        XCTAssertEqual(link.file("Ride.fit", in: courses)?.data, Data("old".utf8))
        XCTAssertEqual(link.folders[courses]?.count, 1, "the staged copy is removed")
    }

    func testReplaceKeepsTheStagedCopyWhenTheFinalWriteFails() throws {
        let link = FakeLink()
        link.add("Ride.fit", data: Data("old".utf8), in: courses)
        link.faults = [.none, .nothing]
        XCTAssertThrowsError(try MTPTransfers.replace(link, localFile: local, in: courses, named: "Ride.fit", storageID: 1))
        let files = try XCTUnwrap(link.folders[courses])
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].name.hasPrefix("Ride.fit.") && files[0].name.hasSuffix(".tmp"))
        XCTAssertEqual(files[0].data, content)
    }

    func testReplaceWithoutAnOldFileIsAnUpload() throws {
        let link = FakeLink()
        try MTPTransfers.replace(link, localFile: local, in: courses, named: "Ride.fit", storageID: 1)
        XCTAssertEqual(link.sentNames, ["Ride.fit"])
    }
}

final class MTPDeviceTests: XCTestCase {
    private final class Opener: @unchecked Sendable {
        let lock = NSLock()
        var links: [FakeLink] = []
        var fail = false

        func open() throws -> any MTPLink {
            lock.lock()
            defer { lock.unlock() }
            if fail { throw MTPError.noDeviceAttached }
            let link = FakeLink()
            links.append(link)
            return link
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return links.count
        }
    }

    func testWorkSharesOneConnectionAndNeverOverlaps() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .seconds(30)) { try opener.open() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try await device.perform { link, storage in try link.entries(in: ["Garmin"], storageID: storage.id) }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(opener.count, 1)
        XCTAssertEqual(opener.links[0].maximumRunning, 1)
    }

    func testAConnectionErrorClosesTheConnection() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .seconds(30)) { try opener.open() }
        _ = try await device.status()
        do {
            _ = try await device.perform { _, _ in throw MTPError.operationFailed("USB gone") }
            XCTFail("expected an error")
        } catch {}
        let open = await device.isOpen
        XCTAssertFalse(open)
        _ = try await device.status()
        XCTAssertEqual(opener.count, 2)
    }

    func testStoragesAreReadOncePerConnectionAndByStatus() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .seconds(30)) { try opener.open() }
        for _ in 0..<5 {
            _ = try await device.perform { _, storage in storage.id }
        }
        XCTAssertEqual(opener.links[0].storageReads, 1)
        _ = try await device.status()
        XCTAssertEqual(opener.links[0].storageReads, 2)
    }

    func testARequestErrorKeepsTheConnection() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .seconds(30)) { try opener.open() }
        do {
            _ = try await device.perform { link, storage in try link.entries(in: ["Nowhere"], storageID: storage.id) }
            XCTFail("expected an error")
        } catch {}
        let open = await device.isOpen
        XCTAssertTrue(open)
    }

    func testStatusRetriesOnceWithANewConnection() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .seconds(30)) { try opener.open() }
        _ = try await device.status()
        opener.links[0].failStorages = true
        let status = try await device.status()
        XCTAssertEqual(status.identity.product, "Fake Edge")
        XCTAssertEqual(opener.count, 2)
    }

    func testStatusReportsAnUnpluggedDevice() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .seconds(30)) { try opener.open() }
        _ = try await device.status()
        opener.links[0].failStorages = true
        opener.fail = true
        do {
            _ = try await device.status()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MTPError, .noDeviceAttached)
        }
    }

    func testTheConnectionClosesWhenIdle() async throws {
        let opener = Opener()
        let device = MTPDevice(idleTimeout: .milliseconds(50)) { try opener.open() }
        _ = try await device.status()
        var open = await device.isOpen
        XCTAssertTrue(open)
        try await Task.sleep(for: .milliseconds(300))
        open = await device.isOpen
        XCTAssertFalse(open)
    }
}
