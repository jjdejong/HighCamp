import XCTest
@testable import BaseCampCore

final class ScaleBarTests: XCTestCase {
    func testPicksTheLargestRoundLengthWithinTheFraction() {
        XCTAssertEqual(ScaleBar.roundLength(2_000, fraction: 0.2), 200)
        XCTAssertEqual(ScaleBar.roundLength(10_000, fraction: 0.2), 2_000)
        XCTAssertEqual(ScaleBar.roundLength(5_000, fraction: 0.25), 1_000)
        XCTAssertEqual(ScaleBar.roundLength(1.6, fraction: 0.2), 0.2)
    }

    func testTheResultNeverExceedsTheFraction() {
        for total in stride(from: 0.37, through: 250_000, by: 1_731.9) {
            let length = ScaleBar.roundLength(total, fraction: 0.2)
            XCTAssertNotNil(length)
            XCTAssertLessThanOrEqual(length ?? .infinity, total * 0.2)
            XCTAssertGreaterThan(length ?? 0, total * 0.2 / 2.5)
        }
    }

    func testNoLengthForNothingToMeasure() {
        XCTAssertNil(ScaleBar.roundLength(0, fraction: 0.2))
        XCTAssertNil(ScaleBar.roundLength(-5, fraction: 0.2))
    }
}
