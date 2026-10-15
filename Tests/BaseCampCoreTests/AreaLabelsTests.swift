import XCTest
@testable import BaseCampCore

final class AreaLabelsTests: XCTestCase {
    /// A ring of points given in metres east and north of 45° N, 5° E.
    private func ring(_ metres: [(Double, Double)]) -> [Coordinate] {
        metres.map { east, north in
            Coordinate(latitude: 45 + north / 111_132, longitude: 5 + east / (111_320 * cos(45 * Double.pi / 180)))
        }
    }

    private func square(at east: Double, _ north: Double, side: Double) -> [Coordinate] {
        ring([(east, north), (east + side, north), (east + side, north + side), (east, north + side)])
    }

    private let view = (
        southWest: Coordinate(latitude: 44.95, longitude: 4.93), northEast: Coordinate(latitude: 45.05, longitude: 5.07)
    )

    func testKindsFollowTheGarminTypes() {
        XCTAssertEqual(AreaLabels.kind(of: 0x3C), .water) // large lake
        XCTAssertEqual(AreaLabels.kind(of: 0x3E), .water)
        XCTAssertEqual(AreaLabels.kind(of: 0x50), .nature) // forest
        XCTAssertEqual(AreaLabels.kind(of: 0x17), .nature) // city park
        XCTAssertEqual(AreaLabels.kind(of: 0x0A), .other) // school
        XCTAssertNil(AreaLabels.kind(of: 0x03), "built-up areas: their towns are named")
        XCTAssertNil(AreaLabels.kind(of: 0x13), "buildings")
        XCTAssertNil(AreaLabels.kind(of: 0x05), "parking")
        XCTAssertNil(AreaLabels.kind(of: 0x10301), "version 2 types")
        XCTAssertEqual(AreaLabels.kind(of: 0x23), .other, "types outside Garmin's list are named too")
    }

    func testTheStyleColourDecidesTheKind() {
        XCTAssertEqual(AreaLabels.kind(red: 0x99, green: 0xB3, blue: 0xCC), .water) // OFM's lakes
        XCTAssertEqual(AreaLabels.kind(red: 0xAD, green: 0xD1, blue: 0x9E), .nature) // a park green
        XCTAssertEqual(AreaLabels.kind(red: 0xD9, green: 0xD0, blue: 0xC9), .other) // a grey-beige
    }

    func testTheNameSitsInsideAConcaveArea() throws {
        // A U open to the north, 1 km wide: its middle is outside; the name must be in one of the arms or the base.
        let u = ring([(0, 0), (1000, 0), (1000, 1000), (700, 1000), (700, 300), (300, 300), (300, 1000), (0, 1000)])
        let area = NamedArea(name: "Lac en U", kind: .water, rings: [u])

        let label = try XCTUnwrap(AreaLabels.place([area], in: view, metersPerPoint: 5).first)

        XCTAssertTrue(AreaLabels.contains(u, label.coordinate), "the name is inside the water")
        XCTAssertEqual(label.name, "Lac en U")
        XCTAssertEqual(label.kind, .water)
    }

    func testAreasTooSmallOnScreenAreNotNamed() {
        let pond = NamedArea(name: "Mare", kind: .water, rings: [square(at: 0, 0, side: 60)])

        XCTAssertTrue(AreaLabels.place([pond], in: view, metersPerPoint: 10).isEmpty, "6 points across")
        XCTAssertEqual(AreaLabels.place([pond], in: view, metersPerPoint: 0.5).count, 1, "120 points across")
    }

    func testALongNameNeedsAWiderArea() {
        // 500 m across at 5 m per point is 100 points: room for a short name, not for a long one.
        let field = square(at: 0, 0, side: 500)
        let short = NamedArea(name: "Stade", kind: .other, rings: [field])
        let long = NamedArea(name: "Aire d'Accueil des Gens du Voyage de la Villa", kind: .other, rings: [field])

        XCTAssertEqual(AreaLabels.place([short], in: view, metersPerPoint: 5).count, 1)
        XCTAssertTrue(AreaLabels.place([long], in: view, metersPerPoint: 5).isEmpty)
    }

    func testPiecesOfOneAreaGetOneName() {
        // A forest split in two by a map cell edge, and a far-away forest of the same name.
        let west = square(at: 0, 0, side: 1000)
        let east = square(at: 1000, 0, side: 1000)
        let far = square(at: 0, 3000, side: 1000)
        let forest = NamedArea(name: "Bois", kind: .nature, rings: [west, east, far])

        let labels = AreaLabels.place([forest], in: view, metersPerPoint: 10)

        XCTAssertEqual(labels.count, 2, "one for the split forest, one for the far one")
    }

    func testAnAreaPartlyInViewIsNamedInTheVisiblePart() throws {
        // 10 km wide; the view shows only its eastern edge.
        let big = square(at: -10_000, -1000, side: 10_000)
        let narrow = (
            southWest: Coordinate(latitude: 44.98, longitude: 4.995), northEast: Coordinate(latitude: 45.02, longitude: 5.01)
        )
        let area = NamedArea(name: "Parc", kind: .nature, rings: [big])

        let label = try XCTUnwrap(AreaLabels.place([area], in: narrow, metersPerPoint: 5).first)

        XCTAssertGreaterThanOrEqual(label.coordinate.longitude, narrow.southWest.longitude)
        XCTAssertLessThanOrEqual(label.coordinate.longitude, narrow.northEast.longitude)
    }

    func testTheNameKeepsClearOfPlaceNames() throws {
        // A 2 km square with a town name written across its middle.
        let square = square(at: 0, 0, side: 2000)
        let middle = ring([(1000, 1000)])[0]
        let town = LabelBox(center: middle, width: 120, height: 16)
        let area = NamedArea(name: "Parc", kind: .nature, rings: [square])

        let label = try XCTUnwrap(AreaLabels.place([area], in: view, metersPerPoint: 5, avoiding: [town]).first)

        XCTAssertTrue(AreaLabels.contains(square, label.coordinate))
        // The town's box is 600 m wide and 80 m tall at 5 m per point; the name is out of it.
        let east = (label.coordinate.longitude - middle.longitude) * 111_320 * cos(45 * Double.pi / 180)
        let north = (label.coordinate.latitude - middle.latitude) * 111_132
        XCTAssertTrue(abs(east) > 300 || abs(north) > 40, "at \(east), \(north) m from the town")
    }

    func testLargerAreasComeFirst() {
        let lake = NamedArea(name: "Lac", kind: .water, rings: [square(at: 0, 0, side: 3000)])
        let park = NamedArea(name: "Parc", kind: .nature, rings: [square(at: 4000, 0, side: 500)])

        let labels = AreaLabels.place([park, lake], in: view, metersPerPoint: 5)

        XCTAssertEqual(labels.map(\.name), ["Lac", "Parc"])
        XCTAssertGreaterThan(labels[0].importance, labels[1].importance)
    }
}
