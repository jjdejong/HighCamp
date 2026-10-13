import XCTest
@testable import BaseCampCore

final class ElevationApplyTests: XCTestCase {
    private func point(_ latitude: Double, elevation: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: latitude, longitude: 5), elevation: elevation)
    }

    func testFilledHeightsAreAppliedWhenTheTrackIsUnchanged() throws {
        let original = Track(name: "Ride", segments: [[point(45), point(45.001), point(45.002)]])
        let filled = Track(name: "Ride", segments: [[point(45, elevation: 100), point(45.001, elevation: 110), point(45.002, elevation: 120)]])

        let result = try XCTUnwrap(original.applyingElevations(from: filled, computedFrom: original))

        XCTAssertEqual(result.segments[0].map(\.elevation), [100, 110, 120])
    }

    func testHeightsAreAppliedAcrossSegmentsInOrder() throws {
        let original = Track(name: "Ride", segments: [[point(45)], [point(45.001), point(45.002)]])
        let filled = Track(name: "Ride", segments: [[point(45, elevation: 1)], [point(45.001, elevation: 2), point(45.002, elevation: 3)]])

        let result = try XCTUnwrap(original.applyingElevations(from: filled, computedFrom: original))

        XCTAssertEqual(result.segments.map { $0.map(\.elevation) }, [[1], [2, 3]])
    }

    func testAHeightEditedMeanwhileIsKept() throws {
        let original = Track(name: "Ride", segments: [[point(45), point(45.001), point(45.002)]])
        // The user typed a height for the middle point while the model was being read.
        var current = original
        current.segments[0][1].elevation = 555
        let filled = Track(name: "Ride", segments: [[point(45, elevation: 100), point(45.001, elevation: 110), point(45.002, elevation: 120)]])

        let result = try XCTUnwrap(current.applyingElevations(from: filled, computedFrom: original))

        XCTAssertEqual(result.segments[0].map(\.elevation), [100, 555, 120])
    }

    func testPointsTheModelDidNotFillKeepTheirHeight() throws {
        let original = Track(name: "Ride", segments: [[point(45, elevation: 50), point(45.001)]])
        let filled = Track(name: "Ride", segments: [[point(45, elevation: 50), point(45.001)]])

        let result = try XCTUnwrap(original.applyingElevations(from: filled, computedFrom: original))

        XCTAssertEqual(result.segments[0].map(\.elevation), [50, nil])
    }

    func testChangedPointCountLeavesTheTrackAlone() {
        let original = Track(name: "Ride", segments: [[point(45), point(45.001)]])
        let filled = Track(name: "Ride", segments: [[point(45, elevation: 1), point(45.001, elevation: 2)]])
        var current = original
        current.segments[0].append(point(45.002))

        XCTAssertNil(current.applyingElevations(from: filled, computedFrom: original))
    }

    func testMovedPointLeavesTheTrackAlone() {
        let original = Track(name: "Ride", segments: [[point(45), point(45.001)]])
        let filled = Track(name: "Ride", segments: [[point(45, elevation: 1), point(45.001, elevation: 2)]])
        var current = original
        current.segments[0][1].coordinate = Coordinate(latitude: 45.5, longitude: 5)

        XCTAssertNil(current.applyingElevations(from: filled, computedFrom: original))
    }

    func testRouteHeightsAreAppliedAndEditsKept() throws {
        let original = Route(name: "Loop", points: [RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5)), RoutePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5))])
        var current = original
        current.updateStop(at: 0) { $0.name = "Start" }
        let filled = Route(id: original.id, name: "Loop", points: [
            RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 300),
            RoutePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5), elevation: 310),
        ])

        let result = try XCTUnwrap(current.applyingElevations(from: filled, computedFrom: original))

        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.points.map(\.elevation), [300, 310])
        XCTAssertEqual(result.points[0].name, "Start")
    }

    func testRouteWithAMovedPointLeavesTheRouteAlone() {
        let original = Route(name: "Loop", points: [RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5))])
        let filled = Route(name: "Loop", points: [RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 300)])
        var current = original
        current.moveStop(at: 0, to: Coordinate(latitude: 46, longitude: 5))

        XCTAssertNil(current.applyingElevations(from: filled, computedFrom: original))
    }
}
