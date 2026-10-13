import XCTest
@testable import BaseCampCore

final class PictureProjectionTests: XCTestCase {
    /// Web Mercator y, in 0...1, computed here independently of the code under test.
    private func mercatorY(_ latitude: Double) -> Double {
        let radians = latitude * .pi / 180
        return (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
    }

    /// Checks that the corners and some interior coordinates land where Web Mercator puts them, to within a pixel,
    /// and that the picture is not stretched: it has the same pixels per unit across and down.
    private func assertPlacesAtWebMercator(
        _ projection: PictureProjection,
        interior: [Coordinate],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let top = mercatorY(projection.north)
        let bottom = mercatorY(projection.south)

        let northWest = projection.point(Coordinate(latitude: projection.north, longitude: projection.west))
        XCTAssertEqual(northWest.x, 0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(northWest.y, 0, accuracy: 1, file: file, line: line)
        let southEast = projection.point(Coordinate(latitude: projection.south, longitude: projection.east))
        XCTAssertEqual(southEast.x, projection.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(southEast.y, projection.height, accuracy: 1, file: file, line: line)

        for coordinate in interior {
            let point = projection.point(coordinate)
            let expectedX = (coordinate.longitude - projection.west) / (projection.east - projection.west) * projection.width
            let expectedY = (mercatorY(coordinate.latitude) - top) / (bottom - top) * projection.height
            XCTAssertEqual(point.x, expectedX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(point.y, expectedY, accuracy: 1, file: file, line: line)
        }

        // Web Mercator is square in its own units: a whole world is 360 degrees of longitude and one unit of y.
        let pixelsPerXUnit = projection.width * 360 / (projection.east - projection.west)
        let pixelsPerYUnit = projection.height / (bottom - top)
        XCTAssertEqual(pixelsPerYUnit / pixelsPerXUnit, 1, accuracy: 1e-6, file: file, line: line)
    }

    func testWideAreaPlacesCoordinatesAtWebMercatorPositions() {
        // Two degrees of longitude by half a degree of latitude: the picture is widened north and south.
        let projection = PictureProjection(north: 45.5, east: 7, south: 45, west: 5, width: 1600, height: 1200)

        assertPlacesAtWebMercator(projection, interior: [
            Coordinate(latitude: 45.2, longitude: 5.5),
            Coordinate(latitude: 45.4, longitude: 6.9),
            Coordinate(latitude: 45.0, longitude: 6.0),
        ])
    }

    func testTallAreaIsWidenedEastAndWestNotStretched() {
        // A north-south track: one degree of latitude by a few hundred metres of longitude, in a wide picture.
        let projection = PictureProjection(north: 46, east: 5.01, south: 45, west: 5, width: 1600, height: 1200)

        XCTAssertEqual(projection.north, 46, accuracy: 1e-9)
        XCTAssertEqual(projection.south, 45, accuracy: 1e-9)
        XCTAssertGreaterThan(projection.east - projection.west, 0.01)
        assertPlacesAtWebMercator(projection, interior: [
            Coordinate(latitude: 45.5, longitude: 5.005),
            Coordinate(latitude: 45.2, longitude: 5.009),
        ])
    }
}
