import XCTest
@testable import BaseCampCore

final class FITActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func samplePoints() -> [CoursePoint] {
        (0..<12).map { index in
            CoursePoint(
                coordinate: Coordinate(latitude: 45.0 + Double(index) * 0.0008, longitude: 5.0 + Double(index) * 0.0004),
                elevation: 300 + Double(index) * 2
            )
        }
    }

    /// Seconds from the start to each point at the default speed of 20 km/h.
    private func expectedOffsets() -> [Double] {
        let points = samplePoints()
        var total = 0.0
        var result = [0.0]
        for (previous, next) in zip(points, points.dropFirst()) {
            total += Geodesy.distance(from: previous.coordinate, to: next.coordinate)
            result.append(total / (20 * 1000 / 3600))
        }
        return result
    }

    func testReadsRecordPositionsAltitudeAndTime() throws {
        let data = try FITCourse.encode(name: "Round trip", points: samplePoints(), startTime: start)

        let track = try FITActivity.read(data, name: "Imported")

        XCTAssertEqual(track.name, "Round trip", "a course keeps its own name")
        XCTAssertEqual(track.segments.count, 1)
        let points = track.segments[0]
        XCTAssertEqual(points.count, 12)
        let offsets = expectedOffsets()
        for (index, point) in points.enumerated() {
            XCTAssertEqual(point.coordinate.latitude, 45.0 + Double(index) * 0.0008, accuracy: 1e-6)
            XCTAssertEqual(point.coordinate.longitude, 5.0 + Double(index) * 0.0004, accuracy: 1e-6)
            // Altitude is stored in steps of 0.2 m.
            XCTAssertEqual(try XCTUnwrap(point.elevation), 300 + Double(index) * 2, accuracy: 0.2)
            // Timestamps are whole seconds, so they can be half a second from the exact offset.
            XCTAssertEqual(try XCTUnwrap(point.time).timeIntervalSince(start), offsets[index], accuracy: 0.5)
        }
    }

    func testRoutePointsWithoutElevationReadBackWithoutElevation() throws {
        let points = [
            CoursePoint(coordinate: Coordinate(latitude: 10, longitude: 20)),
            CoursePoint(coordinate: Coordinate(latitude: 10.001, longitude: 20.001)),
        ]
        let data = try FITCourse.encode(name: "Flat", points: points, startTime: start)

        let track = try FITActivity.read(data, name: "Flat")

        XCTAssertEqual(track.segments[0].count, 2)
        XCTAssertNil(track.segments[0][0].elevation)
    }

    func testRejectsFilesThatAreNotFIT() {
        let data = Data("this is not a FIT file at all".utf8)

        XCTAssertThrowsError(try FITActivity.read(data, name: "Text")) { error in
            XCTAssertEqual(error as? FITReadError, .notFITFile)
        }
    }

    func testRejectsTruncatedFiles() throws {
        let full = try FITCourse.encode(name: "Cut short", points: samplePoints(), startTime: start)
        let truncated = full.prefix(full.count - 20)

        XCTAssertThrowsError(try FITActivity.read(Data(truncated), name: "Cut")) { error in
            XCTAssertEqual(error as? FITReadError, .truncated)
        }
    }
}

extension FITActivityTests {
    /// Prints what the reader finds in a file named by FIT_READ_PATH, for comparing with Garmin's decoder.
    /// Skipped unless the variable is set, for example:
    ///   FIT_READ_PATH=/tmp/activity.fit swift test --filter FITActivityTests/testPrintExternalFile
    func testPrintExternalFile() throws {
        guard let path = ProcessInfo.processInfo.environment["FIT_READ_PATH"] else {
            throw XCTSkip("set FIT_READ_PATH to read an external file")
        }
        let track = try FITActivity.read(try Data(contentsOf: URL(fileURLWithPath: path)), name: "external")
        let points = track.segments.flatMap { $0 }
        print("POINTS \(points.count)")
        if let first = points.first, let last = points.last {
            print("FIRST \(first.coordinate.latitude) \(first.coordinate.longitude) \(first.time?.timeIntervalSince1970 ?? 0)")
            print("LAST \(last.coordinate.latitude) \(last.coordinate.longitude) \(last.time?.timeIntervalSince1970 ?? 0)")
        }
    }
}
