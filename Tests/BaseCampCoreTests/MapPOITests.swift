import XCTest
@testable import BaseCampCore

final class MapPOITests: XCTestCase {
    /// Points near Grenoble. At zoom 16 a 32-point square is about 170 m across there.
    private func poi(_ type: Int, _ latitude: Double, _ longitude: Double, priority: Int, name: String? = nil) -> MapPOI {
        MapPOI(type: type, coordinate: Coordinate(latitude: latitude, longitude: longitude), name: name, priority: priority)
    }

    func testPriorityPutsLabelledNamesFirst() {
        XCTAssertGreaterThan(MapPOI.priority(named: true, labelled: true), MapPOI.priority(named: true, labelled: false))
        XCTAssertGreaterThan(MapPOI.priority(named: true, labelled: false), MapPOI.priority(named: false, labelled: true))
        XCTAssertEqual(MapPOI.priority(named: false, labelled: true), MapPOI.priority(named: false, labelled: false))
    }

    func testPassesAndSummitsAreLandmarks() {
        XCTAssertTrue(poi(0x6401, 45, 5, priority: 3).isLandmark)
        XCTAssertTrue(poi(0x6616, 45, 5, priority: 3).isLandmark)
        XCTAssertFalse(poi(0x2A0E, 45, 5, priority: 3).isLandmark)
    }

    func testBelowZoom15OnlyLandmarksAreShown() {
        let cafe = poi(0x2A0E, 45.188, 5.724, priority: 3, name: "Café")
        let pass = poi(0x6401, 45.300, 5.830, priority: 3, name: "Col")

        XCTAssertEqual(MapPOI.shown([cafe, pass], zoom: 14), [pass])
        XCTAssertEqual(MapPOI.shown([cafe, pass], zoom: 15).count, 2)
    }

    /// The view's names are thinned at the whole zoom below the view's, the tiles at either; a point shown at one
    /// zoom must be shown at the next.
    func testAPointShownAtOneZoomIsShownAtTheNext() {
        let points = (0..<600).map { index in
            poi(0x2A00 + index % 9, 45.18 + Double(index % 30) * 0.0003, 5.72 + Double(index / 30) * 0.0004, priority: index % 4)
        }
        for zoom in 15..<19 {
            let coarse = Set(MapPOI.shown(points, zoom: zoom).map(\.coordinate))
            let fine = Set(MapPOI.shown(points, zoom: zoom + 1).map(\.coordinate))
            XCTAssertTrue(coarse.isSubset(of: fine), "zoom \(zoom)")
        }
    }

    func testTheMostImportantPointOfACrowdedSpotIsShown() {
        let bench = poi(0x5001, 45.18801, 5.72401, priority: 0)
        let pass = poi(0x6401, 45.18802, 5.72402, priority: 3, name: "Col")

        let shown = MapPOI.shown([bench, pass], zoom: 16)

        XCTAssertEqual(shown, [pass])
    }

    func testPointsFarApartAreBothShown() {
        let a = poi(0x5001, 45.188, 5.724, priority: 0)
        let b = poi(0x5001, 45.198, 5.744, priority: 0)

        XCTAssertEqual(MapPOI.shown([a, b], zoom: 16).count, 2)
    }

    func testZoomingInShowsMore() {
        // About 30 m apart: one square at zoom 15, two squares at zoom 19.
        let a = poi(0x2A00, 45.1880, 5.7240, priority: 1, name: "A")
        let b = poi(0x2A00, 45.1880, 5.7244, priority: 1, name: "B")

        XCTAssertEqual(MapPOI.shown([a, b], zoom: 15).count, 1)
        XCTAssertEqual(MapPOI.shown([a, b], zoom: 19).count, 2)
    }

    func testTiesGoToTheSmallerTypeWhateverTheOrder() {
        let cafe = poi(0x2A0E, 45.18801, 5.72401, priority: 1, name: "Café")
        let shop = poi(0x2E03, 45.18802, 5.72402, priority: 1, name: "Shop")

        XCTAssertEqual(MapPOI.shown([cafe, shop], zoom: 16), [cafe])
        XCTAssertEqual(MapPOI.shown([shop, cafe], zoom: 16), [cafe])
    }

    /// Two tiles read overlapping sets of points; where they overlap, they must choose the same ones.
    func testTheChoiceDoesNotDependOnWhichOtherPointsWereRead() {
        let points = (0..<400).map { index in
            poi(0x2E00 + index % 7, 45.18 + Double(index % 20) * 0.0007, 5.72 + Double(index / 20) * 0.0009, priority: index % 3)
        }
        let west = points.filter { $0.coordinate.longitude < 5.732 }
        let east = points.filter { $0.coordinate.longitude > 5.725 }

        let all = MapPOI.shown(points, zoom: 17)
        let inBoth: (MapPOI) -> Bool = { $0.coordinate.longitude > 5.727 && $0.coordinate.longitude < 5.730 }
        let fromWest = MapPOI.shown(west, zoom: 17).filter(inBoth)
        let fromEast = MapPOI.shown(east, zoom: 17).filter(inBoth)
        let fromAll = all.filter(inBoth)

        XCTAssertFalse(fromAll.isEmpty)
        XCTAssertEqual(Set(fromWest.map(\.coordinate)), Set(fromAll.map(\.coordinate)))
        XCTAssertEqual(Set(fromEast.map(\.coordinate)), Set(fromAll.map(\.coordinate)))
    }
}

final class POICategoryTests: XCTestCase {
    func testTypesFallIntoTheirFamilies() {
        XCTAssertEqual(POICategory.of(0x2A00), .food) // restaurant
        XCTAssertEqual(POICategory.of(0x2B01), .lodging) // hotel
        XCTAssertEqual(POICategory.of(0x2E02), .shopping) // supermarket
        XCTAssertEqual(POICategory.of(0x2F06), .services) // bank
        XCTAssertEqual(POICategory.of(0x2F08), .transport) // bus stop
        XCTAssertEqual(POICategory.of(0x2F0A), .transport) // parking
        XCTAssertEqual(POICategory.of(0x1102), .transport) // train station (OFM)
        XCTAssertEqual(POICategory.of(0x1108), .barriers) // bollard (OFM)
        XCTAssertEqual(POICategory.of(0x3200), .barriers) // gate
        XCTAssertEqual(POICategory.of(0x5001), .amenities) // bench (OFM)
        XCTAssertEqual(POICategory.of(0x6401), .manMade) // pass, as Garmin files it
        XCTAssertEqual(POICategory.of(0x6511), .water) // spring
        XCTAssertEqual(POICategory.of(0x6616), .land) // summit
        XCTAssertEqual(POICategory.of(0x10301), .other)
    }
}
