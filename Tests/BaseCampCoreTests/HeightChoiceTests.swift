import XCTest
@testable import BaseCampCore

final class HeightChoiceTests: XCTestCase {
    func testTheFirstSourceIsUsedWhenItCoversTheLine() {
        XCTAssertEqual(HeightChoice.combine([500, 510], [498, 507]), [500, 510])
    }

    func testTheOtherSourceIsUsedWholeRatherThanMixed() {
        // The first has a gap; the other covers every point, so the line takes all its heights from it.
        XCTAssertEqual(HeightChoice.combine([500, nil, 520], [498, 507, 516]), [498, 507, 516])
    }

    func testMixingIsTheLastResort() {
        XCTAssertEqual(HeightChoice.combine([500, nil, nil], [nil, 507, nil]), [500, 507, nil])
        XCTAssertEqual(HeightChoice.combine([500, nil, nil], [nil, 507, nil], mixing: false), [500, nil, nil])
    }

    func testTrackHeightsGoToThePointsInOrder() {
        let c = { (latitude: Double) in Coordinate(latitude: latitude, longitude: 5) }
        let track = Track(name: "T", segments: [
            [TrackPoint(coordinate: c(45.0), elevation: 400), TrackPoint(coordinate: c(45.1))],
            [TrackPoint(coordinate: c(45.2))],
        ])

        let (kept, filled, missing) = track.withElevations([401, 410, nil], replaceExisting: false)
        XCTAssertEqual(kept.segments.flatMap { $0.map(\.elevation) }, [400, 410, nil])
        XCTAssertEqual(filled, 1)
        XCTAssertEqual(missing, 1)

        let (replaced, _, _) = track.withElevations([401, 410, 420], replaceExisting: true)
        XCTAssertEqual(replaced.segments.flatMap { $0.map(\.elevation) }, [401, 410, 420])
    }
}
