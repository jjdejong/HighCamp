import XCTest
@testable import BaseCampCore

final class FITLocationsTests: XCTestCase {
    /// A Locations.fit as the Edge writes it: file_id, then one definition for message 29 and a data message per location.
    private func file(_ locations: [(name: String, latitude: Double, longitude: Double, altitude: Double?)], bigEndian: Bool = false) -> Data {
        var body: [UInt8] = []
        func number<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: bigEndian ? value.bigEndian : value.littleEndian, Array.init)
        }
        // file_id: type 8 (locations).
        body += [0x40, 0, bigEndian ? 1 : 0] + number(UInt16(0)) + [1, 0, 1, 0x00]
        body += [0x00, 8]
        // location: name (16-byte string), latitude, longitude, altitude, time.
        body += [0x41, 0, bigEndian ? 1 : 0] + number(UInt16(29)) + [5, 0, 16, 0x07, 1, 4, 0x85, 2, 4, 0x85, 4, 2, 0x84, 253, 4, 0x86]
        for location in locations {
            var name = Array(location.name.utf8.prefix(15))
            name += [UInt8](repeating: 0, count: 16 - name.count)
            body += [0x01] + name
            body += number(Int32((location.latitude * 2_147_483_648 / 180).rounded()))
            body += number(Int32((location.longitude * 2_147_483_648 / 180).rounded()))
            body += number(location.altitude.map { UInt16(($0 + 500) * 5) } ?? 0xFFFF)
            body += number(UInt32(1_100_000_000))
        }
        var header: [UInt8] = [14, 0x20, 0x34, 0x08]
        header += withUnsafeBytes(of: UInt32(body.count).littleEndian, Array.init)
        header += Array(".FIT".utf8) + [0, 0]
        return Data(header + body + [0, 0])
    }

    func testLocationsBecomeWaypoints() throws {
        let data = file([("Col de Porte", 45.2906, 5.7715, 1326), ("Refuge", 45.3012, 5.8234, nil)])

        let waypoints = try FITLocations.read(data)

        XCTAssertEqual(waypoints.map(\.name), ["Col de Porte", "Refuge"])
        XCTAssertEqual(waypoints[0].coordinate.latitude, 45.2906, accuracy: 1e-6)
        XCTAssertEqual(waypoints[0].coordinate.longitude, 5.7715, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(waypoints[0].elevation), 1326, accuracy: 0.2)
        XCTAssertNil(waypoints[1].elevation, "no altitude")
        XCTAssertEqual(waypoints[0].time, Date(timeIntervalSince1970: 1_100_000_000 + 631_065_600))
    }

    func testBigEndianMessagesAreRead() throws {
        let waypoints = try FITLocations.read(file([("Ouest", 45.1, -1.5, 12)], bigEndian: true))

        XCTAssertEqual(waypoints.first?.coordinate.longitude ?? 0, -1.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(waypoints.first?.elevation), 12, accuracy: 0.2)
    }

    func testAFileWithoutLocationsHasNone() throws {
        XCTAssertTrue(try FITLocations.read(file([])).isEmpty)
    }
}
