import XCTest
@testable import BaseCampCore

final class PointFilterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Points `stepMetres` apart going north, one every `stepSeconds`. Each point's heart rate is its index.
    private func line(_ count: Int, stepMetres: Double = 100, stepSeconds: Double = 10, withTimes: Bool = true) -> [TrackPoint] {
        (0..<count).map { index in
            TrackPoint(
                coordinate: Coordinate(latitude: 45 + stepMetres * Double(index) / 111_195.0, longitude: 5),
                elevation: 100,
                time: withTimes ? start.addingTimeInterval(Double(index) * stepSeconds) : nil,
                heartRate: Double(index)
            )
        }
    }

    func testPointDistancesMatchTheProfile() {
        let eastern = line(3).map { point -> TrackPoint in
            var moved = point
            moved.coordinate.longitude += 0.01
            return moved
        }
        let track = Track(name: "Two parts", segments: [line(4), eastern])
        let profile = track.profile(of: .elevation).map(\.distanceMeters)
        let distances = track.pointDistances.flatMap { $0 }
        XCTAssertEqual(distances.count, profile.count)
        for (index, distance) in distances.enumerated() {
            XCTAssertEqual(distance, profile[index], accuracy: 1e-6)
        }
        XCTAssertEqual(track.pointDistances[0][3], 300, accuracy: 0.5)
    }

    func testRemovingADistanceRangeDropsThosePoints() {
        let track = Track(name: "Ride", segments: [line(10)])
        // The points are 0, 100 … 900 m along; 300, 400 and 500 m lie in the range.
        guard let trimmed = track.removingPoints(distanceIn: 250...550) else { return XCTFail("nothing removed") }
        XCTAssertEqual(trimmed.segments[0].map(\.heartRate), [0, 1, 2, 6, 7, 8, 9])
        XCTAssertEqual(trimmed.segments[0][2].coordinate, track.segments[0][2].coordinate)
    }

    func testRemovingARangeWithNoPointsReturnsNil() {
        let track = Track(name: "Ride", segments: [line(10)])
        XCTAssertNil(track.removingPoints(distanceIn: 5_000...6_000))
    }

    func testRemovingAWholeSegmentDropsIt() {
        let eastern = line(3).map { point -> TrackPoint in
            var moved = point
            moved.coordinate.longitude += 0.01
            return moved
        }
        let track = Track(name: "Two parts", segments: [line(4), eastern])
        // The second segment starts after the first one's 300 m: its points run from 300 m to 500 m.
        guard let trimmed = track.removingPoints(distanceIn: 290...1_000) else { return XCTFail("nothing removed") }
        XCTAssertEqual(trimmed.segments.count, 1)
        XCTAssertEqual(trimmed.segments[0].map(\.heartRate), [0, 1, 2])
    }

    func testThinningKeepsAPointEveryInterval() {
        // One point every 10 s for 300 s: 31 points, 0 to 30.
        let track = Track(name: "Ride", segments: [line(31)])
        let thinned = track.thinned(everySeconds: 30)
        XCTAssertEqual(thinned.segments[0].map(\.heartRate), [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30])
        XCTAssertEqual(thinned.segments[0][1].time, track.segments[0][3].time)
    }

    func testThinningKeepsAPointEveryDistance() {
        // One point every 100 m for 2 km: 21 points. A point is kept once 250 m past the last kept one.
        let track = Track(name: "Ride", segments: [line(21)])
        let thinned = track.thinned(everyMetres: 250)
        XCTAssertEqual(thinned.segments[0].map(\.heartRate), [0, 3, 6, 9, 12, 15, 18, 20])
        let distances = track.pointDistances[0]
        let kept = thinned.segments[0].compactMap { point in point.heartRate.map { Int($0) } }
        for pair in zip(kept, kept.dropFirst()).dropLast() {
            XCTAssertGreaterThanOrEqual(distances[pair.1] - distances[pair.0], 250)
        }
    }

    func testThinningKeepsEveryPointWithoutTimes() {
        let track = Track(name: "Ride", segments: [line(12, withTimes: false)])
        XCTAssertEqual(track.thinned(everySeconds: 30).segments[0].count, 12)
    }

    func testThinningKeepsTheEndsOfEachSegment() {
        let eastern = line(4).map { point -> TrackPoint in
            var moved = point
            moved.coordinate.longitude += 0.01
            return moved
        }
        let track = Track(name: "Two parts", segments: [line(4), eastern])
        let thinned = track.thinned(everyMetres: 1_000)
        XCTAssertEqual(thinned.segments.count, 2)
        XCTAssertEqual(thinned.segments.map { $0.map(\.heartRate) }, [[0, 3], [0, 3]])
    }
}
