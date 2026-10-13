import BaseCampCore
import CoreLocation
import Foundation

extension Coordinate {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Display strings shared by the inspector and the status bar.
enum Format {
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func duration(_ range: ClosedRange<Date>) -> String? {
        seconds(range.upperBound.timeIntervalSince(range.lowerBound))
    }

    /// Hours, minutes and seconds as 1:05:09, the way the Edge and BaseCamp show elapsed time.
    static func seconds(_ interval: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: max(0, interval))
    }
}
