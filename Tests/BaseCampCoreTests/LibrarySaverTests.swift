import XCTest
@testable import BaseCampCore

/// Collects the errors a saver reports, from its queue, for the test to read.
private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func add(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    var first: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errors.first
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return errors.count
    }
}

final class LibrarySaverTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySaverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var fileURL: URL { folder.appendingPathComponent("Library.json") }
    private var backupFolder: URL { folder.appendingPathComponent("Backups") }
    private var savingURL: URL { folder.appendingPathComponent("Library.json.saving") }

    /// A library with one collection of the given name. The collection's identifier is fixed, so two libraries made
    /// with the same name are equal.
    private func library(_ name: String) -> Library {
        Library(collections: [LibraryCollection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: name)])
    }

    private func makeSaver(
        idle: TimeInterval = 0.05,
        maximum: TimeInterval = 1.0,
        backupInterval: TimeInterval = 1800,
        kept: Int = 5,
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> LibrarySaver {
        let saver = LibrarySaver(
            fileURL: fileURL,
            backupFolder: backupFolder,
            idleDelay: idle,
            maximumDelay: maximum,
            backupInterval: backupInterval,
            keptBackups: kept
        )
        saver.onError = onError
        return saver
    }

    /// Waits, polling, until the condition holds or the timeout passes.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func backupNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backupFolder.path)) ?? []).sorted()
    }

    func testBurstOfChangesIsWrittenOnceWithTheLastValue() throws {
        let saver = makeSaver(idle: 0.05)

        for index in 0..<20 {
            saver.schedule(library("Library \(index)"))
        }
        waitUntil { saver.writesMade >= 1 }
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertGreaterThanOrEqual(saver.writesMade, 1)
        XCTAssertLessThanOrEqual(saver.writesMade, 2)
        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("Library 19"))
    }

    func testSteadyChangesAreWrittenWithinTheMaximumDelay() {
        let saver = makeSaver(idle: 0.5, maximum: 0.3)

        // A change every 50 ms for a second: the quiet period never comes, so the maximum delay must write.
        for index in 0..<20 {
            saver.schedule(library("Steady \(index)"))
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertGreaterThanOrEqual(saver.writesMade, 2)
    }

    func testFlushWritesAtOnceAndWithNothingPendingWritesNothing() throws {
        let saver = makeSaver(idle: 60)

        saver.schedule(library("Flushed"))
        try saver.flush()

        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("Flushed"))
        XCTAssertEqual(saver.writesMade, 1)

        try saver.flush()
        XCTAssertEqual(saver.writesMade, 1)
    }

    func testAFailedWriteIsReportedOnceAndLeavesNoSavingFile() throws {
        // A folder where the library file should be: the write cannot replace it.
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let errors = ErrorCollector()
        let saver = makeSaver(idle: 0.05, onError: { errors.add($0) })

        saver.schedule(library("Blocked"))
        waitUntil { errors.count >= 1 }
        XCTAssertEqual(errors.count, 1)

        // Another attempt fails too, but the run of failures is reported once.
        XCTAssertThrowsError(try saver.flush())
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savingURL.path))
    }

    func testAFailedWriteLeavesTheOldFileAsItWas() throws {
        try LibraryFile.save(library("Old"), to: fileURL)
        // A read-only folder: neither the new file nor a backup can be written in it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let saver = makeSaver(idle: 60)

        saver.schedule(library("New"))
        XCTAssertThrowsError(try saver.flush())

        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("Old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savingURL.path))
    }

    func testALeftoverSaveFileIsRemovedAndNotRead() throws {
        try LibraryFile.save(library("Real"), to: fileURL)
        try "a save that a crash cut short".write(to: savingURL, atomically: true, encoding: .utf8)

        _ = makeSaver()

        XCTAssertFalse(FileManager.default.fileExists(atPath: savingURL.path))
        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("Real"))
    }

    func testTheFirstWriteBacksUpTheExistingFileAndLaterOnesDoNotWithinTheInterval() throws {
        try LibraryFile.save(library("A"), to: fileURL)
        let saver = makeSaver(idle: 60, backupInterval: 1800)

        saver.schedule(library("B"))
        try saver.flush()

        let names = backupNames()
        XCTAssertEqual(names.count, 1)
        let backup = try XCTUnwrap(names.first.map { backupFolder.appendingPathComponent($0).appendingPathComponent("Library.json") })
        XCTAssertEqual(try LibraryFile.load(from: backup), library("A"))

        saver.schedule(library("C"))
        try saver.flush()

        XCTAssertEqual(backupNames().count, 1)
        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("C"))
    }

    func testAFailedBackupIsReportedButTheLibraryIsStillSaved() throws {
        try LibraryFile.save(library("A"), to: fileURL)
        // A file where the backup folder should be: the backup cannot be made.
        try Data().write(to: backupFolder)
        let errors = ErrorCollector()
        let saver = makeSaver(idle: 60) { errors.add($0) }

        saver.schedule(library("B"))
        try saver.flush()

        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("B"))
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first is LibrarySaver.BackupError)
    }

    func testOnlyTheNewestBackupsAreKept() throws {
        try LibraryFile.save(library("A"), to: fileURL)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        for day in 1...7 {
            let name = String(format: "Library-202001%02d-000000.json", day)
            try "{}".write(to: backupFolder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let saver = makeSaver(idle: 60, kept: 5)

        saver.schedule(library("B"))
        try saver.flush()

        let names = backupNames()
        XCTAssertEqual(names.count, 5)
        XCTAssertTrue(names.contains("Library-20200107-000000.json"))
        XCTAssertTrue(names.contains("Library-20200104-000000.json"))
        XCTAssertFalse(names.contains("Library-20200103-000000.json"))
        XCTAssertFalse(names.contains("Library-20200101-000000.json"))
    }

    func testBackupsKeepTheLinesAndOldBackupFilesAndFoldersArePrunedTogether() throws {
        let lined = Library(tracks: [Track(name: "Ride", segments: [[TrackPoint(coordinate: Coordinate(latitude: 45, longitude: 6))]])])
        try LibraryFile.save(lined, to: fileURL)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        try "{}".write(to: backupFolder.appendingPathComponent("Library-20200101-000000.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backupFolder.appendingPathComponent("Library-20200102-000000"),
                                                withIntermediateDirectories: true)
        let saver = makeSaver(idle: 60, kept: 2)

        saver.schedule(library("B"))
        try saver.flush()

        let names = backupNames()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("Library-20200102-000000"))
        let newest = try XCTUnwrap(names.first { !$0.hasPrefix("Library-2020") })
        XCTAssertEqual(try LibraryFile.load(from: backupFolder.appendingPathComponent(newest).appendingPathComponent("Library.json")), lined)
        XCTAssertEqual(try LibraryFile.load(from: fileURL), library("B"))
    }

    func testTheWrittenFileIsCompactAndLoadsBack() throws {
        let saver = makeSaver(idle: 60)
        let saved = library("Compact")

        saver.schedule(saved)
        try saver.flush()

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(try LibraryFile.load(from: fileURL), saved)
    }
}
