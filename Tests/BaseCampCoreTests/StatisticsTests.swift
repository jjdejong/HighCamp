import XCTest
@testable import BaseCampCore

final class StatisticsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A track that moves north at a steady speed, one point every `interval` seconds.
    private func track(metresPerStep: Double, steps: Int, interval: TimeInterval, elevations: [Double]? = nil) -> Track {
        let degreesPerStep = metresPerStep / 111_195.0
        let points = (0..<steps).map { index in
            TrackPoint(
                coordinate: Coordinate(latitude: 45 + degreesPerStep * Double(index), longitude: 5),
                elevation: elevations?[index],
                time: start.addingTimeInterval(interval * Double(index))
            )
        }
        return Track(name: "Test", segments: [points])
    }

    func testDistanceAndTotalTime() {
        let track = track(metresPerStep: 100, steps: 11, interval: 10)
        let stats = track.statistics
        XCTAssertEqual(stats.distanceMeters, 1000, accuracy: 1)
        XCTAssertEqual(stats.pointCount, 11)
        XCTAssertEqual(stats.totalTime ?? -1, 100, accuracy: 0.001)
    }

    func testMovingTimeLeavesOutStops() {
        // Fifteen steps of 10 s. Steps 6 to 9 stand still; the other eleven move 100 m each.
        var points: [TrackPoint] = []
        var latitude = 45.0
        var time = start
        for index in 0...15 {
            if index > 0 && !(6...9).contains(index) {
                latitude += 100.0 / 111_195.0
            }
            points.append(TrackPoint(coordinate: Coordinate(latitude: latitude, longitude: 5), time: time))
            time = time.addingTimeInterval(10)
        }
        let stats = Track(name: "Stops", segments: [points]).statistics
        XCTAssertEqual(stats.movingTime ?? -1, 110, accuracy: 0.001)
        XCTAssertEqual(stats.averageSpeed ?? -1, 10, accuracy: 0.01)
    }

    func testMaximumSpeedIgnoresGPSSpikes() {
        var track = track(metresPerStep: 50, steps: 4, interval: 5)
        // One point jumps 50 km in 5 seconds, which is not a real speed.
        track.segments[0][2].coordinate = Coordinate(latitude: 45.45, longitude: 5)
        let stats = track.statistics
        XCTAssertLessThan(stats.maximumSpeed ?? 0, ActivityStatistics.maximumPlausibleSpeed)
    }

    func testClimbIgnoresJitterBelowTheThreshold() {
        // Noise of about 1 m around a flat road.
        let values = [100.0, 101, 100, 101, 99, 100.5, 101, 100]
        let climb = ActivityStatistics.climb(values, threshold: 3)
        XCTAssertEqual(climb?.ascent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(climb?.descent ?? -1, 0, accuracy: 0.001)
    }

    func testClimbAndDescentOfAHill() {
        // Up 10 m (100 to 110), down 7 m (110 to 103), up 5 m (103 to 108).
        let values = [100.0, 102, 104, 106, 108, 110, 107, 105, 103, 105, 108]
        let climb = ActivityStatistics.climb(values, threshold: 3)
        XCTAssertEqual(climb?.ascent ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(climb?.descent ?? -1, 7, accuracy: 0.001)
    }

    func testStatisticsFromElevations() {
        let track = track(metresPerStep: 100, steps: 4, interval: 10, elevations: [100, 120, 110, 130])
        let stats = track.statistics
        XCTAssertEqual(stats.minimumElevation ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(stats.maximumElevation ?? -1, 130, accuracy: 0.001)
        XCTAssertEqual(stats.ascentMeters ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(stats.descentMeters ?? -1, 10, accuracy: 0.001)
    }

    func testNoElevationsMeansNoClimb() {
        let stats = track(metresPerStep: 100, steps: 3, interval: 10).statistics
        XCTAssertNil(stats.ascentMeters)
        XCTAssertNil(stats.minimumElevation)
    }

    func testRouteStatisticsUseElevationsWithoutTimes() {
        let route = Route(name: "Route", points: [
            RoutePoint(coordinate: Coordinate(latitude: 45, longitude: 5), elevation: 200),
            RoutePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5), elevation: 230),
        ])
        let stats = route.statistics
        XCTAssertNil(stats.totalTime)
        XCTAssertEqual(stats.ascentMeters ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(stats.distanceMeters, route.lengthMeters, accuracy: 0.001)
    }

    func testElevationProfileDistanceAndSkippedPoints() {
        let track = track(metresPerStep: 100, steps: 4, interval: 10, elevations: [100, 120, 110, 130])
        let profile = track.elevationProfile
        XCTAssertEqual(profile.count, 4)
        XCTAssertEqual(profile[0].distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(profile[3].distanceMeters, 300, accuracy: 1)
        XCTAssertEqual(profile[2].value, 110, accuracy: 0.001)
    }

    func testElevationProfileSkipsPointsWithoutElevation() {
        var track = track(metresPerStep: 100, steps: 3, interval: 10, elevations: [100, 110, 120])
        track.segments[0][1].elevation = nil
        let profile = track.elevationProfile
        XCTAssertEqual(profile.map(\.value), [100, 120])
        XCTAssertEqual(profile[1].distanceMeters, 200, accuracy: 1)
    }
}
