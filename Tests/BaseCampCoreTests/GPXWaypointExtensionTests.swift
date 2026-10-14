import XCTest
@testable import BaseCampCore

final class GPXWaypointExtensionTests: XCTestCase {
    private let header = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3">
    """

    /// Made-up place details, for the tests only.
    private func waypointFile() -> Data {
        Data("""
        \(header)
          <wpt lat="45.1" lon="5.2">
            <name>Cafe</name>
            <extensions>
              <gpxx:WaypointExtension>
                <gpxx:Proximity>50.0</gpxx:Proximity>
                <gpxx:Address>
                  <gpxx:StreetAddress>10 Test Street</gpxx:StreetAddress>
                  <gpxx:City>Testville</gpxx:City>
                  <gpxx:State>Testshire</gpxx:State>
                  <gpxx:Country>Testland</gpxx:Country>
                  <gpxx:PostalCode>00000</gpxx:PostalCode>
                </gpxx:Address>
                <gpxx:PhoneNumber>+00 0 00 00 00 00</gpxx:PhoneNumber>
              </gpxx:WaypointExtension>
            </extensions>
          </wpt>
        </gpx>
        """.utf8)
    }

    private func waypointXML(_ waypoint: Waypoint) -> String {
        String(decoding: GPX.write(Library(waypoints: [waypoint])), as: UTF8.self)
    }

    func testReadsProximityAddressAndPhone() throws {
        let waypoint = try XCTUnwrap(GPX.read(waypointFile()).library.waypoints.first)
        XCTAssertEqual(waypoint.proximity, 50)
        XCTAssertEqual(waypoint.address, WaypointAddress(
            street: "10 Test Street", city: "Testville", state: "Testshire",
            postalCode: "00000", country: "Testland", phone: "+00 0 00 00 00 00"
        ))
    }

    func testAPlainWaypointHasNoAddressOrProximity() throws {
        let plain = Data("""
        \(header)
          <wpt lat="45.1" lon="5.2"><name>Plain</name></wpt>
        </gpx>
        """.utf8)
        let waypoint = try XCTUnwrap(GPX.read(plain).library.waypoints.first)
        XCTAssertNil(waypoint.proximity)
        XCTAssertNil(waypoint.address)
    }

    func testAPlainWaypointWritesNoExtensions() {
        let xml = waypointXML(Waypoint(name: "Plain", coordinate: Coordinate(latitude: 45, longitude: 5)))
        XCTAssertFalse(xml.contains("extensions"))
    }

    func testProximityAndAddressRoundTrip() throws {
        let original = Waypoint(
            name: "Cafe",
            coordinate: Coordinate(latitude: 45.1, longitude: 5.2),
            proximity: 50,
            address: WaypointAddress(street: "10 Test Street", city: "Testville", state: "Testshire",
                                     postalCode: "00000", country: "Testland", phone: "+00 0 00 00 00 00")
        )
        let read = try XCTUnwrap(GPX.read(GPX.write(Library(waypoints: [original]))).library.waypoints.first)
        XCTAssertEqual(read.proximity, original.proximity)
        XCTAssertEqual(read.address, original.address)
    }

    func testAPhoneNumberAloneIsWrittenWithoutAnAddressBlock() throws {
        let original = Waypoint(
            name: "Phone only",
            coordinate: Coordinate(latitude: 45, longitude: 5),
            address: WaypointAddress(phone: "+00 0 00 00 00 00")
        )
        let xml = waypointXML(original)
        XCTAssertTrue(xml.contains("<gpxx:PhoneNumber>+00 0 00 00 00 00</gpxx:PhoneNumber>"))
        XCTAssertFalse(xml.contains("<gpxx:Address>"))
        let read = try XCTUnwrap(GPX.read(GPX.write(Library(waypoints: [original]))).library.waypoints.first)
        XCTAssertEqual(read.address?.phone, "+00 0 00 00 00 00")
    }
}
