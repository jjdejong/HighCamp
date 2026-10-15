import XCTest
@testable import BaseCampCore

final class FITCourseTests: XCTestCase {
    private let samplePoints = [
        CoursePoint(coordinate: Coordinate(latitude: 45.0, longitude: 5.0), elevation: 300),
        CoursePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5.0005), elevation: 302),
        CoursePoint(coordinate: Coordinate(latitude: 45.002, longitude: 5.001), elevation: nil),
    ]

    func testCRCMatchesStandardCheckValue() {
        // CRC-16/ARC check value for the ASCII digits "123456789".
        XCTAssertEqual(FITChecksum.crc16(Array("123456789".utf8)), 0xBB3D)
    }

    func testFileHeaderDescribesTheFile() throws {
        let data = try FITCourse.encode(name: "Test course", points: samplePoints)
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes[0], 14, "header size")
        XCTAssertEqual(bytes[1], 0x20, "protocol 2.0")
        XCTAssertEqual(Array(bytes[8..<12]), Array(".FIT".utf8))

        let dataSize = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        XCTAssertEqual(Int(dataSize), bytes.count - 14 - 2, "data size excludes header and trailing CRC")
    }

    func testChecksumsAreCorrect() throws {
        let data = try FITCourse.encode(name: "Test course", points: samplePoints)
        let bytes = [UInt8](data)

        let headerCRC = UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        XCTAssertEqual(headerCRC, FITChecksum.crc16(bytes[0..<12]))

        let fileCRC = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        XCTAssertEqual(fileCRC, FITChecksum.crc16(bytes[0..<(bytes.count - 2)]))
    }

    func testCourseNameIsStoredAsText() throws {
        let data = try FITCourse.encode(name: "Col du Galibier", points: samplePoints)

        XCTAssertNotNil(data.range(of: Data("Col du Galibier".utf8)))
    }

    func testNameIsTruncatedToDeviceLimit() {
        let long = String(repeating: "A", count: 80)

        XCTAssertEqual(FITCourse.truncatedName(long).utf8.count, FITCourse.maxNameBytes)
    }

    func testTruncationKeepsWholeCharacters() {
        // "é" is two bytes in UTF-8. The cut must not split a character.
        let name = String(repeating: "é", count: 40)
        let truncated = FITCourse.truncatedName(name)

        XCTAssertLessThanOrEqual(truncated.utf8.count, FITCourse.maxNameBytes)
        XCTAssertEqual(truncated, String(repeating: "é", count: 24))
    }

    func testEmptyNameFallsBackToDefault() {
        XCTAssertEqual(FITCourse.truncatedName("   "), "Course")
    }

    func testFileNameIsSafeForTheDevice() {
        XCTAssertEqual(FITCourse.fileName(for: "Lac du Bourget / J2"), "Lac_du_Bourget___J2.fit")
        XCTAssertEqual(FITCourse.fileName(for: ""), "Course.fit")
    }

    /// Distance along the points, in metres, at each point.
    private func distances(_ points: [CoursePoint]) -> [Double] {
        var total = 0.0
        var result = [0.0]
        for (previous, next) in zip(points, points.dropFirst()) {
            total += Geodesy.distance(from: previous.coordinate, to: next.coordinate)
            result.append(total)
        }
        return result
    }

    func testRecordTimesFollowDistanceAtTheAssumedSpeed() throws {
        // About 556 m between points, so 20 km/h spaces them about 100 s apart.
        let points = (0..<10).map { CoursePoint(coordinate: Coordinate(latitude: 45 + Double($0) * 0.005, longitude: 5)) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try FITCourse.encode(name: "Pace", points: points, startTime: start)
        let times = try FITActivity.read(data, name: "Pace").segments[0].compactMap(\.time)

        XCTAssertEqual(times.count, points.count)
        for (time, metres) in zip(times, distances(points)) {
            XCTAssertEqual(time.timeIntervalSince(start), metres / (20 * 1000 / 3600), accuracy: 0.5)
        }
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 100, accuracy: 1)
        }
    }

    func testAssumedSpeedChangesTheSpacing() throws {
        let points = (0..<10).map { CoursePoint(coordinate: Coordinate(latitude: 45 + Double($0) * 0.005, longitude: 5)) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try FITCourse.encode(name: "Slow", points: points, startTime: start, assumedSpeedKilometresPerHour: 10)
        let times = try FITActivity.read(data, name: "Slow").segments[0].compactMap(\.time)

        XCTAssertEqual(times[1].timeIntervalSince(times[0]), 200, accuracy: 1)
    }

    func testZeroSpeedIsAnError() {
        XCTAssertThrowsError(try FITCourse.encode(name: "Stopped", points: samplePoints, assumedSpeedKilometresPerHour: 0)) { error in
            XCTAssertEqual(error as? FITCourseError, .invalidSpeed)
        }
    }

    func testTooFewPointsIsAnError() {
        XCTAssertThrowsError(try FITCourse.encode(name: "One", points: [samplePoints[0]])) { error in
            XCTAssertEqual(error as? FITCourseError, .tooFewPoints)
        }
    }

    func testRouteAndTrackBecomeCoursePoints() {
        let route = Route(name: "R", points: [
            RoutePoint(coordinate: Coordinate(latitude: 1, longitude: 2)),
            RoutePoint(coordinate: Coordinate(latitude: 3, longitude: 4)),
        ])
        let track = Track(name: "T", segments: [
            [TrackPoint(coordinate: Coordinate(latitude: 5, longitude: 6), elevation: 100)],
            [TrackPoint(coordinate: Coordinate(latitude: 7, longitude: 8))],
        ])

        XCTAssertEqual(route.coursePoints.count, 2)
        XCTAssertNil(route.coursePoints[0].elevation)
        XCTAssertEqual(track.coursePoints.count, 2)
        XCTAssertEqual(track.coursePoints[0].elevation, 100)
    }

    // MARK: Heights

    /// A route edited by hand: its stops have no height, the router's legs between them do. The device reads a
    /// "no height" record as a real altitude, so every stop was a spike (an 885 m route showed 30,746 m of ascent).
    func testStopsWithoutHeightTakeTheirNeighboursHeights() throws {
        let route = Route(name: "Edited", stops: [
            RouteStop(coordinate: Coordinate(latitude: 45.000, longitude: 5)),
            RouteStop(coordinate: Coordinate(latitude: 45.004, longitude: 5)),
            RouteStop(coordinate: Coordinate(latitude: 45.008, longitude: 5)),
        ], legs: [
            RouteLeg(shape: [
                RoutePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5), elevation: 500),
                RoutePoint(coordinate: Coordinate(latitude: 45.003, longitude: 5), elevation: 540),
            ], method: .calculated),
            RouteLeg(shape: [
                RoutePoint(coordinate: Coordinate(latitude: 45.005, longitude: 5), elevation: 560),
                RoutePoint(coordinate: Coordinate(latitude: 45.007, longitude: 5), elevation: 600),
            ], method: .calculated),
        ])

        let data = try FITCourse.encode(name: "Edited", points: route.coursePoints)
        let heights = try FITActivity.read(data, name: "Edited").segments[0].map(\.elevation)

        XCTAssertEqual(heights.count, 7)
        let expected: [Double] = [500, 500, 540, 550, 560, 600, 600]
        for (height, wanted) in zip(heights, expected) {
            XCTAssertEqual(try XCTUnwrap(height), wanted, accuracy: 0.2)
        }
    }

    func testNoHeightsStayUnset() throws {
        let points = (0..<4).map { CoursePoint(coordinate: Coordinate(latitude: 45 + Double($0) * 0.001, longitude: 5)) }

        let data = try FITCourse.encode(name: "Flat", points: points)

        XCTAssertTrue(try FITActivity.read(data, name: "Flat").segments[0].allSatisfy { $0.elevation == nil })
        let lap = try XCTUnwrap(messages(data).first { $0.global == 19 })
        XCTAssertEqual(lap.fields[21], [0xFF, 0xFF], "no total ascent without heights")
    }

    func testLapCarriesTheAscentAndDescent() throws {
        let heights: [Double?] = [300, 350, nil, 420, 380, 400]
        let points = heights.enumerated().map { index, height in
            CoursePoint(coordinate: Coordinate(latitude: 45 + Double(index) * 0.001, longitude: 5), elevation: height)
        }

        let data = try FITCourse.encode(name: "Climb", points: points)
        let lap = try XCTUnwrap(messages(data).first { $0.global == 19 })

        // 300 → 420 is 120 up, 420 → 380 is 40 down, 380 → 400 is 20 up.
        XCTAssertEqual(lap.fields[21].map(littleEndian), 140)
        XCTAssertEqual(lap.fields[22].map(littleEndian), 40)
    }

    /// Laid out as Garmin Connect writes courses, which an Edge 1040 reads the heights of: heights in
    /// enhanced_altitude (78), not altitude (2), and timer start and stop events around the records.
    func testCourseIsLaidOutAsGarminConnectWritesIt() throws {
        let data = try FITCourse.encode(name: "Layout", points: samplePoints)
        let all = messages(data)

        XCTAssertEqual(all.map(\.global).filter { $0 != 20 }, [0, 49, 31, 19, 21, 21])
        let records = all.filter { $0.global == 20 }
        XCTAssertEqual(records.count, samplePoints.count)
        XCTAssertTrue(records.allSatisfy { $0.fields[78] != nil && $0.fields[2] == nil })
        let events = all.filter { $0.global == 21 }
        XCTAssertEqual(events.map { $0.fields[1] }, [[0], [4]], "timer start, then stop all")
        XCTAssertEqual(events.first?.fields[253], records.first?.fields[253], "starts at the first point")
        XCTAssertEqual(events.last?.fields[253], records.last?.fields[253], "stops at the last point")
    }

    /// The data messages of a FIT file, by global message number, with each field's bytes.
    private func messages(_ data: Data) -> [(global: UInt16, fields: [UInt8: [UInt8]])] {
        let bytes = [UInt8](data)
        var definitions: [UInt8: (global: UInt16, fields: [(number: UInt8, size: Int)])] = [:]
        var result: [(global: UInt16, fields: [UInt8: [UInt8]])] = []
        var offset = Int(bytes[0])
        while offset < bytes.count - 2 {
            let header = bytes[offset]
            let local = header & 0x0F
            offset += 1
            if header & 0x40 != 0 {
                let global = UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8
                let count = Int(bytes[offset + 4])
                let fields = (0..<count).map { (number: bytes[offset + 5 + 3 * $0], size: Int(bytes[offset + 6 + 3 * $0])) }
                definitions[local] = (global, fields)
                offset += 5 + 3 * count
            } else if let definition = definitions[local] {
                var fields: [UInt8: [UInt8]] = [:]
                for field in definition.fields {
                    fields[field.number] = Array(bytes[offset..<(offset + field.size)])
                    offset += field.size
                }
                result.append((definition.global, fields))
            } else {
                break
            }
        }
        return result
    }

    private func littleEndian(_ bytes: [UInt8]) -> Int {
        bytes.reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    /// Writes a sample course for checking with Garmin's decoder.
    /// Runs only when FIT_DUMP_PATH is set, for example:
    ///   FIT_DUMP_PATH=/tmp/sample.fit swift test --filter FITCourseTests
    func testDumpSampleForExternalCheck() throws {
        guard let path = ProcessInfo.processInfo.environment["FIT_DUMP_PATH"] else {
            throw XCTSkip("set FIT_DUMP_PATH to write a sample file")
        }
        let points = (0..<12).map { index in
            CoursePoint(
                coordinate: Coordinate(latitude: 45.0 + Double(index) * 0.0008, longitude: 5.0 + Double(index) * 0.0004),
                elevation: 300 + Double(index) * 2
            )
        }
        let data = try FITCourse.encode(name: "BCCLONE_SAMPLE", points: points, startTime: Date(timeIntervalSince1970: 1_700_000_000))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
