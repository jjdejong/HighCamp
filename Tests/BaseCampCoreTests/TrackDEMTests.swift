import XCTest
@testable import BaseCampCore

final class TrackDEMTests: XCTestCase {
    /// A 5 km square tile with its south-west corner at the given place, 5 m pixels unless said otherwise.
    private func tile(_ name: String, south: Double, west: Double, size: Double = 0.045, resolution: Double = 5) -> DEMTileInfo {
        DEMTileInfo(path: name, size: 1, modified: nil, north: south + size, south: south, east: west + size, west: west,
                    resolution: resolution, projection: "L93")
    }

    func testOnlyTheTilesNearTheTrackAreChosenFinestFirst() {
        let tiles = [
            tile("a", south: 45.0, west: 5.0),
            tile("b", south: 45.0, west: 5.045),
            tile("far", south: 46.0, west: 6.0),
            tile("fine", south: 45.01, west: 5.01, size: 0.01, resolution: 1),
            tile("beside", south: 45.045, west: 5.0),
        ]
        // East along 45.02° N, from 5.02° to 5.06° E: crosses a and b, and the fine tile.
        let line = [Coordinate(latitude: 45.02, longitude: 5.02), Coordinate(latitude: 45.02, longitude: 5.06)]
        let chosen = TrackDEM.tiles(along: [line], corridor: 100, from: tiles).map(\.path)
        XCTAssertEqual(chosen, ["fine", "a", "b"])
    }

    func testTheCorridorReachesANeighbouringTile() {
        let tiles = [tile("a", south: 45.0, west: 5.0), tile("beside", south: 45.045, west: 5.0)]
        // 100 m south of the tile edge at 45.045°.
        let line = [Coordinate(latitude: 45.0441, longitude: 5.01), Coordinate(latitude: 45.0441, longitude: 5.02)]
        XCTAssertEqual(TrackDEM.tiles(along: [line], corridor: 150, from: tiles).count, 2)
        XCTAssertEqual(TrackDEM.tiles(along: [line], corridor: 50, from: tiles).count, 1)
    }

    func testPlacesAreAddedBetweenFarPoints() {
        let line = [Coordinate(latitude: 45, longitude: 5), Coordinate(latitude: 45.009, longitude: 5)]
        let places = TrackDEM.places(along: line, every: 100)
        // About 1 km: eleven steps of about 91 m.
        XCTAssertEqual(places.count, 12)
        XCTAssertEqual(places.last, line.last)
    }

    func testSampleDistancesKeepTheEndAndALimit() {
        XCTAssertEqual(TrackDEM.sampleDistances(length: 12, step: 5), [0, 5, 10, 12])
        let long = TrackDEM.sampleDistances(length: 100_000, step: 1, limit: 1_000)
        XCTAssertLessThanOrEqual(long.count, 1_001)
        XCTAssertEqual(long.last, 100_000)
    }

    func testATileIsOutlinedByItsCornersWhenKnownElseByItsBox() {
        let box = tile("a", south: 45.0, west: 5.0)
        XCTAssertEqual(box.area.outline, [
            Coordinate(latitude: 45.045, longitude: 5.0), Coordinate(latitude: 45.045, longitude: 5.045),
            Coordinate(latitude: 45.0, longitude: 5.045), Coordinate(latitude: 45.0, longitude: 5.0),
        ])
        let corners = [
            Coordinate(latitude: 45.05, longitude: 5.0), Coordinate(latitude: 45.046, longitude: 5.06),
            Coordinate(latitude: 45.0, longitude: 5.056), Coordinate(latitude: 45.004, longitude: 4.996),
        ]
        let turned = DEMTileInfo(path: "b", size: 1, modified: nil, north: 45.05, south: 45.0, east: 5.06, west: 4.996,
                                 resolution: 1, projection: "L93", corners: corners)
        XCTAssertEqual(turned.area, DEMTileArea(outline: corners, resolution: 1))
    }

    func testTiersCountTheTilesOfEachResolutionFinestFirst() {
        let areas = [
            tile("eu", south: 40.0, west: 0.0, size: 10, resolution: 25).area,
            tile("a", south: 45.0, west: 5.0, resolution: 5).area,
            tile("b", south: 45.0, west: 5.045, resolution: 5.01).area,
            tile("eu2", south: 40.0, west: 10.0, size: 10, resolution: 24.9).area,
            tile("c", south: 45.0, west: 5.09, resolution: 4.99).area,
        ]
        let tiers = TrackDEM.tiers(areas)
        XCTAssertEqual(tiers.map(\.count), [3, 2])
        XCTAssertEqual(tiers.map(\.resolution), [4.99, 24.9])
    }
}
