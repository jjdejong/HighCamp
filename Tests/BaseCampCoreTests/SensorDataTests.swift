import XCTest
@testable import BaseCampCore

final class SensorDataTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ latitude: Double, elevation: Double? = nil, heartRate: Double? = nil, cadence: Double? = nil, power: Double? = nil, temperature: Double? = nil) -> TrackPoint {
        TrackPoint(
            coordinate: Coordinate(latitude: latitude, longitude: 5),
            elevation: elevation,
            heartRate: heartRate,
            cadence: cadence,
            power: power,
            temperature: temperature
        )
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    /// A FIT activity file whose record messages carry a position and the four sensor values, as a device writes them.
    private func fitActivity(_ records: [(latitude: Double, heartRate: UInt8, cadence: UInt8, power: UInt16, temperature: Int8)]) -> Data {
        var body: [UInt8] = [0x40, 0x00, 0x00, 20, 0]   // definition, local type 0, little endian, record (20)
        let fields: [(number: UInt8, size: UInt8, baseType: UInt8)] = [
            (0, 4, 0x85), (1, 4, 0x85), (3, 1, 0x02), (4, 1, 0x02), (7, 2, 0x84), (13, 1, 0x01),
        ]
        body.append(UInt8(fields.count))
        for field in fields {
            body += [field.number, field.size, field.baseType]
        }
        for record in records {
            body.append(0x00)
            body += littleEndian(UInt32(bitPattern: Int32(record.latitude * 2_147_483_648 / 180)))
            body += littleEndian(UInt32(bitPattern: Int32(5.0 * 2_147_483_648 / 180)))
            body.append(record.heartRate)
            body.append(record.cadence)
            body += [UInt8(record.power & 0xFF), UInt8(record.power >> 8)]
            body.append(UInt8(bitPattern: record.temperature))
        }
        var header: [UInt8] = [14, 0x20, 0x34, 0x08]
        header += littleEndian(UInt32(body.count))
        header += Array(".FIT".utf8)
        let headerCRC = FITChecksum.crc16(header)
        header += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        var file = header + body
        let fileCRC = FITChecksum.crc16(file)
        file += [UInt8(fileCRC & 0xFF), UInt8(fileCRC >> 8)]
        return Data(file)
    }

    func testFITRecordsCarryHeartRateCadencePowerAndTemperature() throws {
        let data = fitActivity([
            (45.0, 120, 80, 200, 21),
            (45.001, 0xFF, 0xFF, 0xFFFF, 0x7F),
            (45.002, 150, 90, 250, -3),
        ])

        let points = try XCTUnwrap(FITActivity.read(data, name: "Sensors").segments.first)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].heartRate, 120)
        XCTAssertEqual(points[0].cadence, 80)
        XCTAssertEqual(points[0].power, 200)
        XCTAssertEqual(points[0].temperature, 21)
        // 0xFF, 0xFFFF and 0x7F are the FIT values for "no reading".
        XCTAssertNil(points[1].heartRate)
        XCTAssertNil(points[1].cadence)
        XCTAssertNil(points[1].power)
        XCTAssertNil(points[1].temperature)
        XCTAssertEqual(points[2].temperature, -3)
    }

    func testStatisticsGiveTheAverageAndMaximumOfEachSensor() {
        let track = Track(name: "Ride", segments: [[
            point(45.0, heartRate: 100, power: 200, temperature: 20),
            point(45.001, heartRate: 120, power: 300, temperature: 20),
            point(45.002, cadence: 90),
            point(45.003, heartRate: 140, power: 250),
        ]])

        let stats = track.statistics

        XCTAssertEqual(stats.heartRate, SeriesSummary(average: 120, maximum: 140))
        XCTAssertEqual(stats.power, SeriesSummary(average: 250, maximum: 300))
        XCTAssertEqual(stats.temperature, SeriesSummary(average: 20, maximum: 20))
        XCTAssertEqual(stats.cadence, SeriesSummary(average: 90, maximum: 90))
    }

    func testStatisticsHaveNoSensorValuesWhenThereAreNone() {
        let track = Track(name: "Walk", segments: [[point(45.0), point(45.001, elevation: 300)]])

        XCTAssertNil(track.statistics.heartRate)
        XCTAssertNil(track.statistics.power)
        XCTAssertNil(Route(name: "Loop", points: [RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5))]).statistics.cadence)
    }

    func testSensorProfileLeavesOutPointsWithoutTheValue() {
        let track = Track(name: "Ride", segments: [[
            point(45.0, elevation: 100, heartRate: 100),
            point(45.001, elevation: 110),
            point(45.002, elevation: 120, heartRate: 120),
            point(45.003, elevation: 130, heartRate: 140),
        ]])

        let heart = track.profile(of: .heartRate)

        XCTAssertEqual(heart.map(\.value), [100, 120, 140])
        XCTAssertEqual(heart.map(\.id), [0, 1, 2])
        XCTAssertTrue(zip(heart, heart.dropFirst()).allSatisfy { $0.distanceMeters < $1.distanceMeters })
        XCTAssertEqual(track.profile(of: .elevation).map(\.value), [100, 110, 120, 130])
    }

    func testSensorValuesRoundTripAndOldFilesStillLoad() throws {
        let library = Library(tracks: [Track(name: "Ride", segments: [[point(45.0, heartRate: 150, cadence: 85, power: 260, temperature: 18)]])])
        let back = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(back, library)

        let old = #"{"waypoints":[],"routes":[],"tracks":[{"id":"7F1C2B1E-3A4D-4E5F-9A0B-1C2D3E4F5A6B","name":"Old","segments":[[{"coordinate":{"latitude":45,"longitude":5}}]]}]}"#
        let loaded = try JSONDecoder().decode(Library.self, from: Data(old.utf8))
        XCTAssertNil(loaded.tracks.first?.segments.first?.first?.heartRate)
    }

    func testRoutesProfileOnlyTheirElevation() {
        let route = Route(name: "Loop", points: [
            RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 100),
            RoutePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5), elevation: 120),
        ])

        XCTAssertEqual(route.profile(of: .elevation), route.elevationProfile)
        XCTAssertEqual(route.profile(of: .heartRate), [])
    }

    func testStatisticsListTheSeriesTheItemHas() {
        let track = Track(name: "Ride", segments: [[point(45.0, elevation: 100, heartRate: 120), point(45.001, elevation: 110)]])
        XCTAssertEqual(track.statistics.availableSeries, [.elevation, .heartRate])

        let heartOnly = Track(name: "Strap", segments: [[point(45.0, heartRate: 120)]])
        XCTAssertEqual(heartOnly.statistics.availableSeries, [.heartRate])

        XCTAssertEqual(Track(name: "Empty", segments: [[point(45.0)]]).statistics.availableSeries, [])
    }
}
