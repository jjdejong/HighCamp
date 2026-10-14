import XCTest
@testable import BaseCampCore

final class LineMeasureTests: XCTestCase {
    /// About 111.2 m per 0.001° of latitude.
    private let step = 0.001

    private func northward(_ count: Int, longitude: Double = 5, elevation: (Int) -> Double = { Double($0) }) -> [TrackPoint] {
        (0..<count).map { TrackPoint(coordinate: Coordinate(latitude: 45 + step * Double($0), longitude: longitude), elevation: elevation($0)) }
    }

    func testDistancesMatchTheProfileAndPointDistances() {
        let track = Track(name: "Two parts", segments: [northward(5), northward(3, longitude: 5.01)])
        let measure = track.measure
        XCTAssertEqual(measure.distances.flatMap { $0 }, track.pointDistances.flatMap { $0 })
        XCTAssertEqual(measure.length, track.elevationProfile.last!.distanceMeters, accuracy: 1e-9)
    }

    func testCoordinateIsInterpolatedBetweenPoints() throws {
        let measure = Track(name: "Line", segments: [northward(3)]).measure
        let half = measure.distances[0][1] / 2
        let place = try XCTUnwrap(measure.coordinate(at: half))
        XCTAssertEqual(place.latitude, 45 + step / 2, accuracy: 1e-7)
        XCTAssertEqual(measure.coordinate(at: -10), measure.segments[0][0])
        XCTAssertEqual(measure.coordinate(at: 1e9), measure.segments[0][2])
    }

    func testCoordinateOnALoopFollowsTheDistanceNotThePlace() throws {
        // Out and back along the same line: 0.5 of the way out and 0.5 of the way back are the same place, but the
        // distance tells them apart.
        let out = northward(3)
        let back = Array(out.reversed().dropFirst())
        let measure = Track(name: "Loop", segments: [out + back]).measure
        let leg = measure.distances[0][2]
        let outward = try XCTUnwrap(measure.coordinate(at: leg * 0.25))
        let homeward = try XCTUnwrap(measure.coordinate(at: leg * 1.75))
        XCTAssertEqual(outward.latitude, homeward.latitude, accuracy: 1e-7)
        XCTAssertEqual(measure.distance(segment: 0, index: 3, fraction: 0.5), leg * 1.75, accuracy: 1e-6)
    }

    func testSectionHasInterpolatedEndsAndThePointsBetween() throws {
        let measure = Track(name: "Line", segments: [northward(5)]).measure
        let d = measure.distances[0]
        let pieces = measure.section((d[1] / 2)...(d[3] + (d[4] - d[3]) / 2))
        XCTAssertEqual(pieces.count, 1)
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertEqual(piece.count, 5)
        XCTAssertEqual(piece[0].latitude, 45 + step / 2, accuracy: 1e-7)
        XCTAssertEqual(Array(piece[1...3]), Array(measure.segments[0][1...3]))
        XCTAssertEqual(piece[4].latitude, 45 + step * 3.5, accuracy: 1e-7)
    }

    func testSectionAcrossSegmentsGivesOnePiecePerSegment() {
        let measure = Track(name: "Two parts", segments: [northward(3), northward(3, longitude: 5.01)]).measure
        XCTAssertEqual(measure.section(0...measure.length).map(\.count), [3, 3])
        XCTAssertEqual(measure.section(5_000...6_000).count, 0)
    }

    func testSplitAtDistanceCutsAtTheNearestPoint() throws {
        let track = Track(name: "Ride", segments: [northward(5)])
        let d = track.pointDistances[0]
        let (first, second) = try XCTUnwrap(track.split(atDistance: d[2] + 10))
        XCTAssertEqual(first.segments[0].count, 3)
        XCTAssertEqual(second.segments[0].count, 3)
        XCTAssertEqual(first.segments[0].last, second.segments[0].first)
        XCTAssertNil(track.split(atDistance: 0))
        XCTAssertNil(track.split(atDistance: 1e9))
    }

    func testProfileValueAndGradeAreInterpolated() throws {
        // 1 m higher every point, about 111 m apart: a grade of about 0.9 %.
        let profile = Track(name: "Climb", segments: [northward(10)]).elevationProfile
        let d = profile[3].distanceMeters
        XCTAssertEqual(try XCTUnwrap(profile.value(at: d)), 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.value(at: (profile[3].distanceMeters + profile[4].distanceMeters) / 2)), 3.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.grade(at: d)), 100 / (profile[1].distanceMeters), accuracy: 0.01)
        XCTAssertNil(profile.value(at: -1))
    }

    func testThinningForDrawingKeepsPeaksAndEnds() {
        let profile = Track(name: "Spiky", segments: [northward(1_000) { $0 == 537 ? 900 : 100 }]).elevationProfile
        let thinned = profile.thinnedForDrawing(limit: 100)
        XCTAssertLessThanOrEqual(thinned.count, 102)
        XCTAssertEqual(thinned.first?.id, 0)
        XCTAssertEqual(thinned.last?.id, 999)
        XCTAssertTrue(thinned.contains { $0.value == 900 })
        XCTAssertEqual(thinned.map(\.distanceMeters), thinned.map(\.distanceMeters).sorted())
        XCTAssertEqual(profile.thinnedForDrawing(limit: 2_000).count, 1_000)
    }
}
