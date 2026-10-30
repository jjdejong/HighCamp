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
        // The ends follow the 40 m grade, which blurs them by up to half of that.
        XCTAssertEqual(section.startMeters, 300, accuracy: 25)
        XCTAssertEqual(section.endMeters, 500, accuracy: 25)
        XCTAssertEqual(section.maxGradePercent, 14, accuracy: 0.5)
        XCTAssertTrue(GradeAnalysis.steepSections(inProfile: points, maxGradePercent: 15).isEmpty)
    }

    func testAShortBumpOfTheElevationModelIsNoClimbButALongClimbIs() throws {
        // A regular 8% climb, with a 60 m bump of 10 m such as an elevation model shows (33% up, 33% down), then
        // 400 m at 25%.
        let heights = (0...300).map { step -> Double in
            let metres = Double(step * 10)
            var height = min(metres, 2000) * 0.08
            if (1000...1060).contains(metres) { height += 10 - abs(metres - 1030) / 3 }
            if metres > 2000 { height += min(metres - 2000, 400) * 0.25 }
            return height
        }
        let points = heights.enumerated().map { index, height in
            ElevationProfilePoint(id: index, distanceMeters: Double(index * 10), value: 500 + height,
                                  coordinate: Coordinate(latitude: 45 + Double(index * 10) / 111_320, longitude: 5))
        }
        let sections = GradeAnalysis.steepSections(inProfile: points, maxGradePercent: 20)
        XCTAssertEqual(sections.count, 1, "the bump is not a climb")
        let climb = try XCTUnwrap(sections.first)
        XCTAssertEqual(climb.startMeters, 2000, accuracy: 25)
        XCTAssertEqual(climb.endMeters, 2400, accuracy: 25)
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
