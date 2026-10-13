import XCTest
@testable import BaseCampCore

final class PictureProjectionTests: XCTestCase {
    /// Web Mercator y, in 0...1, computed here independently of the code under test.
    private func mercatorY(_ latitude: Double) -> Double {
        let radians = latitude * .pi / 180
        return (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
    }

    func testWideAreaPlacesCoordinatesAtWebMercatorPositions() {
        // Two degrees of longitude by half a degree of latitude: the picture is widened north and south.
        let projection = PictureProjection(north: 45.5, east: 7, south: 45, west: 5, width: 1600, height: 1200)

        let northWest = projection.point(Coordinate(latitude: projection.north, longitude: 5))
        XCTAssertEqual(northWest.x, 0, accuracy: 1)
        XCTAssertEqual(northWest.y, 0, accuracy: 1)
        let southEast = projection.point(Coordinate(latitude: projection.south, longitude: 7))
        XCTAssertEqual(southEast.x, 1600, accuracy: 1)
        XCTAssertEqual(southEast.y, 1200, accuracy: 1)

        let top = mercatorY(projection.north)
        let bottom = mercatorY(projection.south)
        for (latitude, longitude) in [(45.2, 5.5), (45.4, 6.9), (45.0, 6.0)] {
            let point = projection.point(Coordinate(latitude: latitude, longitude: longitude))
            XCTAssertEqual(point.x, (longitude - 5) / 2 * 1600, accuracy: 1)
            XCTAssertEqual(point.y, (mercatorY(latitude) - top) / (bottom - top) * 1200, accuracy: 1)
        }
    }

    func testWideAreaIsNotStretched() {
        let projection = PictureProjection(north: 45.5, east: 7, south: 45, west: 5, width: 1600, height: 1200)

        // Web Mercator is square in its own units: a whole world is 360 degrees of longitude and one unit of y.
        let pixelsPerXUnit = projection.width * 360 / (projection.east - projection.west)
        let pixelsPerYUnit = projection.height / (mercatorY(projection.south) - mercatorY(projection.north))
        XCTAssertEqual(pixelsPerYUnit / pixelsPerXUnit, 1, accuracy: 1e-6)
    }
}
