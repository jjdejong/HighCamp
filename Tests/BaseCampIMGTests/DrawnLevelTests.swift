import XCTest
@testable import BaseCampIMG

final class DrawnLevelTests: XCTestCase {
    /// OFM's levels: an inherited top level, then levels two bits apart.
    private let levels = [
        GarminMapLevel(level: 4, bits: 17, inherited: true),
        GarminMapLevel(level: 3, bits: 18),
        GarminMapLevel(level: 2, bits: 20),
        GarminMapLevel(level: 1, bits: 22),
        GarminMapLevel(level: 0, bits: 24),
    ]

    func testNormalTakesTheFinestLevelNotFinerThanWanted() {
        XCTAssertEqual(levels.drawnLevel(forBits: 21)?.level, 2)
        XCTAssertEqual(levels.drawnLevel(forBits: 22)?.level, 1)
        XCTAssertNil(levels.drawnLevel(forBits: 17))
    }

    func testEachStepMovesOneLevelWhereverTheZoomIs() {
        // Between levels (21 bits) and on a level (22 bits), one step always changes the level.
        XCTAssertEqual(levels.drawnLevel(forBits: 21, steps: 1)?.level, 1)
        XCTAssertEqual(levels.drawnLevel(forBits: 22, steps: 1)?.level, 0)
        XCTAssertEqual(levels.drawnLevel(forBits: 21, steps: -1)?.level, 3)
        XCTAssertEqual(levels.drawnLevel(forBits: 22, steps: -1)?.level, 2)
        XCTAssertEqual(levels.drawnLevel(forBits: 21, steps: 2)?.level, 0)
    }

    func testStepsStayWithinTheMapsLevels() {
        XCTAssertEqual(levels.drawnLevel(forBits: 24, steps: 2)?.level, 0)
        XCTAssertNil(levels.drawnLevel(forBits: 18, steps: -1))
        // Zoomed out past the coarsest level, one step more detail draws the coarsest level.
        XCTAssertNil(levels.drawnLevel(forBits: 16))
        XCTAssertEqual(levels.drawnLevel(forBits: 16, steps: 1)?.level, 3)
        XCTAssertEqual(levels.drawnLevel(forBits: 16, steps: 2)?.level, 2)
    }
}
