import XCTest
@testable import BaseCampCore

final class StreetLabelsTests: XCTestCase {
    /// A line running east from 5° E at 45° N, in `count` pieces of `step` degrees each.
    private func pieces(_ count: Int, step: Double = 0.001, latitude: Double = 45) -> [[Coordinate]] {
        (0..<count).map { index in
            [Coordinate(latitude: latitude, longitude: 5 + Double(index) * step),
             Coordinate(latitude: latitude, longitude: 5 + Double(index + 1) * step)]
        }
    }

    func testPiecesAreJoinedWhicheverWayTheyRun() {
        var parts = pieces(4)
        parts[1].reverse()
        parts.swapAt(0, 3)
        let chains = StreetLabels.joined(parts)
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0].count, 5)
    }

    func testTheHalvesOfADualCarriagewayAreNotJoinedIntoAHairpin() {
        // Up one side and back down the other, meeting at both ends.
        let north = Coordinate(latitude: 45.01, longitude: 5)
        let south = Coordinate(latitude: 45, longitude: 5)
        let chains = StreetLabels.joined([[south, north], [north, Coordinate(latitude: 45.005, longitude: 5.0002), south]])
        XCTAssertEqual(chains.count, 2)
    }

    func testANameGoesInTheMiddleOfAStreetLongEnough() throws {
        // Ten pieces of about 79 m: a 790 m street. At 1 m per point "Rue Test" needs about 62 m.
        let lines = pieces(10).map { NamedLine(name: "Rue Test", coordinates: $0, importance: 5, isWater: false) }
        let labels = StreetLabels.place(lines, metersPerPoint: 1)
        let label = try XCTUnwrap(labels.first)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(label.coordinate.longitude, 5.005, accuracy: 0.0005)
        XCTAssertEqual(label.angle, 0, accuracy: 1e-6)
    }

    func testShortStreetsAndLongNamesAreLeftOut() {
        let lines = [NamedLine(name: "Rue Test", coordinates: pieces(1)[0], importance: 5, isWater: false)]
        XCTAssertTrue(StreetLabels.place(lines, metersPerPoint: 2).isEmpty)
    }

    func testLongStreetsAreNamedMoreThanOnce() {
        let lines = pieces(60).map { NamedLine(name: "Rue Test", coordinates: $0, importance: 5, isWater: false) }
        // About 4.7 km at 1 m per point: a name every 500 m or so.
        XCTAssertGreaterThan(StreetLabels.place(lines, metersPerPoint: 1).count, 5)
    }

    func testAnglesNeverReadUpsideDown() {
        let a = Coordinate(latitude: 45, longitude: 5)
        let west = Coordinate(latitude: 45, longitude: 4.99)
        let north = Coordinate(latitude: 45.01, longitude: 5)
        XCTAssertEqual(StreetLabels.angle(from: a, to: west), 0, accuracy: 1e-9)
        XCTAssertEqual(StreetLabels.angle(from: a, to: north), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(StreetLabels.angle(from: north, to: a), .pi / 2, accuracy: 1e-9)
    }
}
