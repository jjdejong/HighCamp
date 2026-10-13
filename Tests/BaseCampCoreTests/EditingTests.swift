import XCTest
@testable import BaseCampCore

final class EditingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func line(_ count: Int, stepMetres: Double = 100) -> [TrackPoint] {
        (0..<count).map { index in
            TrackPoint(
                coordinate: Coordinate(latitude: 45 + stepMetres * Double(index) / 111_195.0, longitude: 5),
                elevation: 100 + Double(index),
                time: start.addingTimeInterval(Double(index) * 10)
            )
        }
    }

    func testReversedTrackKeepsDurationAndMovingTime() {
        let track = Track(name: "Ride", segments: [line(6)])
        let reversed = track.reversed()
        XCTAssertEqual(reversed.segments[0].first?.elevation, 105)
        XCTAssertEqual(reversed.segments[0].first?.coordinate.latitude ?? 0, track.segments[0].last?.coordinate.latitude ?? 1, accuracy: 1e-9)
        XCTAssertEqual(reversed.statistics.totalTime ?? -1, track.statistics.totalTime ?? -2, accuracy: 0.001)
        XCTAssertEqual(reversed.statistics.movingTime ?? -1, track.statistics.movingTime ?? -2, accuracy: 0.001)
        XCTAssertEqual(reversed.statistics.distanceMeters, track.statistics.distanceMeters, accuracy: 0.001)
    }

    func testReversedRouteKeepsElevations() {
        let route = Route(name: "Loop", points: [
            RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 100),
            RoutePoint(coordinate: Coordinate(latitude: 45.1, longitude: 5), elevation: 300),
        ])
        let reversed = route.reversed()
        XCTAssertEqual(reversed.points.map(\.elevation), [300, 100])
        XCTAssertEqual(reversed.id, route.id)
    }

    func testSplitSharesThePointNearestTheCut() {
        let track = Track(name: "Ride", segments: [line(10)])
        let target = track.segments[0][4].coordinate
        guard let (first, second) = track.split(nearest: target) else { return XCTFail("no split") }
        XCTAssertEqual(first.segments[0].count, 5)
        XCTAssertEqual(second.segments[0].count, 6)
        XCTAssertEqual(first.segments[0].last?.coordinate, second.segments[0].first?.coordinate)
        XCTAssertEqual(first.name, "Ride (1)")
    }

    func testSplitKeepsGapsBetweenSegments() {
        // The second part sits a kilometre east, so its points are not near the first part.
        let eastern = line(4).map { point -> TrackPoint in
            var moved = point
            moved.coordinate.longitude += 0.01
            return moved
        }
        let track = Track(name: "Two parts", segments: [line(3), eastern])
        let target = track.segments[1][1].coordinate
        guard let (first, second) = track.split(nearest: target) else { return XCTFail("no split") }
        XCTAssertEqual(first.segments.count, 2)
        XCTAssertEqual(second.segments.count, 1)
        XCTAssertEqual(second.segments[0].count, 3)
    }

    func testSimplifyKeepsCornersAndDropsNoise() {
        // A straight run of 50 points with 0.5 m of jitter, then a sharp turn east.
        var points = (0..<50).map { index in
            TrackPoint(coordinate: Coordinate(latitude: 45 + Double(index) * 100 / 111_195.0, longitude: 5 + (index % 2 == 0 ? 0.5 : -0.5) / 111_195.0 / cos(45 * .pi / 180)))
        }
        points += (1...10).map { step in
            TrackPoint(coordinate: Coordinate(latitude: 45 + 49 * 100 / 111_195.0, longitude: 5 + Double(step) * 100 / (111_195.0 * cos(45 * .pi / 180))))
        }
        let simplified = Track(name: "Corner", segments: [points]).simplified(tolerance: 5)
        XCTAssertLessThan(simplified.pointCount, 15)
        XCTAssertEqual(simplified.segments[0].first?.coordinate, points.first?.coordinate)
        XCTAssertEqual(simplified.segments[0].last?.coordinate, points.last?.coordinate)
        // The corner point must survive.
        XCTAssertTrue(simplified.segments[0].contains { $0.coordinate == points[49].coordinate })
    }

    func testSimplifyOfAStraightRouteLeavesItsStops() {
        // A long line: its ends are stops, the rest is shape, which simplifies away.
        let long = Route(name: "Straight", points: line(300).map { RoutePoint(coordinate: $0.coordinate, elevation: $0.elevation) })
        XCTAssertEqual(long.simplified(tolerance: 1).points.count, 2)
        // A short, hand-made route: every point is a stop, and stops are kept, as BaseCamp keeps via points.
        let short = Route(name: "Clicked", points: line(5).map { RoutePoint(coordinate: $0.coordinate) })
        XCTAssertEqual(short.simplified(tolerance: 1).points.count, 5)
    }

    func testCombinedJoinsSegments() {
        let a = Track(name: "A", segments: [line(3)])
        let b = Track(name: "B", segments: [line(2), line(2)])
        let combined = Track.combined([a, b], name: "AB")
        XCTAssertEqual(combined.segments.count, 3)
        XCTAssertEqual(combined.pointCount, 7)
        XCTAssertEqual(combined.name, "AB")
    }

    func testTrackAndRouteConversionsKeepElevations() {
        let track = Track(name: "Ride", segments: [line(4)])
        let route = track.asRoute()
        XCTAssertEqual(route.points.map(\.elevation), [100, 101, 102, 103])
        let back = route.asTrack()
        XCTAssertEqual(back.segments.count, 1)
        XCTAssertEqual(back.segments[0].map(\.elevation), [100, 101, 102, 103])
        XCTAssertNil(back.segments[0][0].time)
    }

    func testNearestPointFindsTheClosestSample() {
        let track = Track(name: "Ride", segments: [line(5)])
        let index = track.nearestPoint(to: track.segments[0][3].coordinate)
        XCTAssertEqual(index?.0, 0)
        XCTAssertEqual(index?.1, 3)
    }
}
