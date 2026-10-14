import XCTest
@testable import BaseCampCore

final class ReliefShadingTests: XCTestCase {
    /// A 5 by 5 grid whose height is `slope(x, y)`, x to the east and y to the south.
    private func grid(_ slope: (Int, Int) -> Double) -> [Double] {
        (0..<5).flatMap { y in (0..<5).map { x in slope(x, y) } }
    }

    private let shading = ReliefShading(strength: 0.5)

    func testFlatGroundGetsTheSameLightShadowEverywhere() {
        let shadows = shading.shadows(heights: grid { _, _ in 300 }, width: 5, height: 5, spacing: 10, exaggeration: 1)
        XCTAssertEqual(shadows.count, 9)
        XCTAssertEqual(Set(shadows).count, 1)
        // Lit at 45°: a little shadow, far from the strongest.
        XCTAssertLessThan(shadows[0], 30)
    }

    func testSlopesFacingAwayFromTheLightAreDarker() {
        // Ground rising to the south-east faces the light from the north-west; rising to the north-west, it faces away.
        let facing = shading.shadows(heights: grid { x, y in Double(x + y) * 10 }, width: 5, height: 5, spacing: 10, exaggeration: 1)
        let away = shading.shadows(heights: grid { x, y in Double(-x - y) * 10 }, width: 5, height: 5, spacing: 10, exaggeration: 1)
        let flat = shading.shadows(heights: grid { _, _ in 0 }, width: 5, height: 5, spacing: 10, exaggeration: 1)
        XCTAssertLessThan(facing[4], flat[4])
        XCTAssertGreaterThan(away[4], flat[4] + 40)
    }

    func testTheSameGroundShadesTheSameAtAnySpacing() {
        // Twice the spacing with twice the height steps is the same slope.
        let near = shading.shadows(heights: grid { x, _ in Double(x) * 10 }, width: 5, height: 5, spacing: 10, exaggeration: 1)
        let far = shading.shadows(heights: grid { x, _ in Double(x) * 20 }, width: 5, height: 5, spacing: 20, exaggeration: 1)
        XCTAssertEqual(near, far)
    }

    func testMissingHeightsCastNoShadow() {
        var heights = grid { x, _ in Double(x) * 10 }
        heights[12] = .nan
        let shadows = shading.shadows(heights: heights, width: 5, height: 5, spacing: 10, exaggeration: 1)
        // The eight points around the hole lose their slope; the slope at the hole itself does not use its height.
        XCTAssertEqual(shadows.filter { $0 == 0 }.count, 8)
        XCTAssertNotEqual(shadows[4], 0)
    }

    func testBlurKeepsMissingHeightsAndSmoothsSteps() {
        let step = (0..<9).map { $0 < 4 ? 0.0 : 90.0 }
        let smooth = ReliefShading.blurred(step, width: 9, height: 1, radius: 1)
        XCTAssertEqual(smooth[3], 30, accuracy: 1e-9)
        XCTAssertEqual(smooth[4], 60, accuracy: 1e-9)
        var holed = step
        holed[2] = .nan
        let blurred = ReliefShading.blurred(holed, width: 9, height: 1, radius: 1)
        XCTAssertTrue(blurred[2].isNaN)
        XCTAssertEqual(blurred[1], 0, accuracy: 1e-9)
    }

    func testExaggerationGrowsWhenZoomedOut() {
        XCTAssertLessThan(ReliefShading.exaggeration(spacing: 2), ReliefShading.exaggeration(spacing: 50))
        XCTAssertLessThanOrEqual(ReliefShading.exaggeration(spacing: 100_000), 12)
    }
}
