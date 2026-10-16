import BaseCampCore
import XCTest

/// Stretches steeper than a profile's grade limit, found on the heights a profile shows, and the colour they are
/// drawn in over the line.
final class SteepStretchTests: XCTestCase {
    /// A profile every 10 m along a meridian: flat, then `climbLength` metres at `grade` percent, then flat.
    private func profile(climbFrom start: Double, length climbLength: Double, grade: Double, total: Double) -> [ElevationProfilePoint] {
        stride(from: 0.0, through: total, by: 10).enumerated().map { index, distance in
            let climbed = min(max(distance - start, 0), climbLength)
            return ElevationProfilePoint(id: index, distanceMeters: distance, value: 500 + climbed * grade / 100,
                                         coordinate: Coordinate(latitude: 45 + distance / 111_320, longitude: 5))
        }
    }

    func testAStretchAboveTheLimitIsFoundAtItsDistances() throws {
        let points = profile(climbFrom: 300, length: 200, grade: 14, total: 1000)
        let sections = GradeAnalysis.steepSections(inProfile: points, maxGradePercent: 10)
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(sections.count, 1)
        // The 40 m window blurs the ends by up to half a window.
        XCTAssertEqual(section.startMeters, 300, accuracy: 25)
        XCTAssertEqual(section.endMeters, 500, accuracy: 25)
        XCTAssertEqual(section.maxGradePercent, 14, accuracy: 0.5)
        XCTAssertTrue(GradeAnalysis.steepSections(inProfile: points, maxGradePercent: 15).isEmpty)
    }

    func testTheProfilesOwnDistancesAreUsed() throws {
        // A track in two segments: the profile does not count the gap, so its distances are what the map uses.
        var points = profile(climbFrom: 300, length: 200, grade: 14, total: 1000)
        for index in points.indices where points[index].distanceMeters > 600 {
            points[index].coordinate.latitude += 0.05
        }
        let section = try XCTUnwrap(GradeAnalysis.steepSections(inProfile: points, maxGradePercent: 10).first)
        XCTAssertEqual(section.startMeters, 300, accuracy: 25)
    }

    func testTheHighlightStandsOutFromTheLine() {
        let orange = SteepHighlight.orange
        // A blue route, a grey or black line: orange.
        XCTAssertEqual(SteepHighlight.colour(against: ItemColor(red: 0.0, green: 0.48, blue: 1.0)), orange)
        XCTAssertEqual(SteepHighlight.colour(against: ItemColor(red: 0.2, green: 0.2, blue: 0.2)), orange)
        // An orange track: red. A red line: yellow.
        XCTAssertEqual(SteepHighlight.colour(against: ItemColor(red: 1.0, green: 0.58, blue: 0.0)), SteepHighlight.red)
        XCTAssertEqual(SteepHighlight.colour(against: ItemColor(red: 0.9, green: 0.1, blue: 0.1)), SteepHighlight.yellow)
    }
}
