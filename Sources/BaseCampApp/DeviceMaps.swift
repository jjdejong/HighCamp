import BaseCampCore
import Foundation

/// A map file on the Edge and how it got there.
struct DeviceMap: Identifiable, Equatable, Sendable {
    let file: DeviceFile
    let kind: DeviceMapKind

    var id: UInt32 { file.id }

    var kindLabel: String {
        switch kind {
        case .builtIn: "Built into the Edge"
        case .licensed: "Licensed, protected"
        case .custom: "Custom map"
        }
    }
}

/// A map copy in progress.
struct MapTransfer: Equatable, Sendable {
    let name: String
    var fraction: Double
}

/// Shared between the transfer thread and the UI. Limits progress reports to 1% steps
/// and carries the cancel request.
final class TransferMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported = -1.0
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// True when progress has moved by at least 1% since the last report, or the transfer is complete.
    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction >= 1 || fraction - lastReported >= 0.01 else { return false }
        lastReported = fraction
        return true
    }
}
