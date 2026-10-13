import Foundation

/// Saves the library in the background. A change is written once things have been quiet for `idleDelay`, and at the
/// latest `maximumDelay` after the first unsaved change, so a long edit is still saved about once a second. Before
/// writing, the file is copied to a `Backups` folder next to it (see `backUpIfDue`).
///
/// All state is used only on `queue`, which is what makes it safe to share the saver between threads.
public final class LibrarySaver: @unchecked Sendable {
    /// Called with the first failure of each run of failed writes. A later success starts a new run.
    /// Set it before the first change is scheduled.
    public var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "BaseCampClone.LibrarySaver")
    private let fileURL: URL
    private let backupFolder: URL
    private let idleDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private let backupInterval: TimeInterval
    private let keptBackups: Int

    // Used only on `queue`.
    private var pending: Library?
    private var firstUnsaved: Date?
    private var scheduledWrite: DispatchWorkItem?
    private var reportedFailure = false
    private var checkedBackupThisSession = false
    private var writeCount = 0

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// `backupFolder` defaults to `Backups` next to `fileURL`, so a test file gets backups of its own.
    public init(
        fileURL: URL,
        backupFolder: URL? = nil,
        idleDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 1.0,
        backupInterval: TimeInterval = 1800,
        keptBackups: Int = 5
    ) {
        self.fileURL = fileURL
        self.backupFolder = backupFolder ?? fileURL.deletingLastPathComponent().appendingPathComponent("Backups")
        self.idleDelay = idleDelay
        self.maximumDelay = maximumDelay
        self.backupInterval = backupInterval
        self.keptBackups = keptBackups
        // A save that a crash cut short leaves its temporary file behind. It is never read, so it is removed.
        try? FileManager.default.removeItem(at: LibraryFile.savingURL(for: fileURL))
    }

    /// Keeps `library` as the newest value to save, and writes it once things have been quiet for `idleDelay`, or
    /// at the latest `maximumDelay` after the first unsaved change.
    public func schedule(_ library: Library) {
        queue.async {
            let now = Date()
            self.pending = library
            let first = self.firstUnsaved ?? now
            self.firstUnsaved = first
            let untilMaximum = first.addingTimeInterval(self.maximumDelay).timeIntervalSince(now)
            let delay = max(0, min(self.idleDelay, untilMaximum))
            self.scheduledWrite?.cancel()
            let work = DispatchWorkItem { self.writePending() }
            self.scheduledWrite = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Writes the pending value now, and returns once it is on disk. Does nothing when nothing is pending.
    public func flush() throws {
        try queue.sync {
            scheduledWrite?.cancel()
            scheduledWrite = nil
            guard let library = pending else { return }
            try write(library)
            markSaved()
        }
    }

    /// The number of writes made so far, for tests.
    var writesMade: Int {
        queue.sync { writeCount }
    }

    /// A scheduled write. A failure keeps the value pending and is reported once; the next change or flush tries again.
    private func writePending() {
        scheduledWrite = nil
        guard let library = pending else { return }
        do {
            try write(library)
            markSaved()
        } catch {
            if !reportedFailure {
                reportedFailure = true
                onError?(error)
            }
        }
    }

    private func markSaved() {
        pending = nil
        firstUnsaved = nil
        reportedFailure = false
    }

    private func write(_ library: Library) throws {
        try backUpIfDue()
        try LibraryFile.save(library, to: fileURL)
        writeCount += 1
    }

    /// Copies the file to `Backups/` before the first write of a session, and again before a write when the newest
    /// backup is older than `backupInterval`. The newest `keptBackups` are kept. Nothing outside `Backups/` is touched.
    private func backUpIfDue() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let existing = backups()
        let due = !checkedBackupThisSession
            || existing.first.map { Date().timeIntervalSince($0.date) > backupInterval } ?? true
        guard due else { return }
        checkedBackupThisSession = true

        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let target = backupFolder.appendingPathComponent("Library-\(Self.stampFormatter.string(from: Date())).json")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fileURL, to: target)
        for old in backups().dropFirst(keptBackups) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    /// The backups in `Backups/`, newest first, from their names: `Library-yyyyMMdd-HHmmss.json`.
    private func backups() -> [(url: URL, date: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupFolder.path)) ?? []
        return names.compactMap { name -> (url: URL, date: Date)? in
            guard name.hasPrefix("Library-"), name.hasSuffix(".json") else { return nil }
            let stamp = name.dropFirst("Library-".count).dropLast(".json".count)
            guard let date = Self.stampFormatter.date(from: String(stamp)) else { return nil }
            return (backupFolder.appendingPathComponent(name), date)
        }
        .sorted { $0.date > $1.date }
    }
}
