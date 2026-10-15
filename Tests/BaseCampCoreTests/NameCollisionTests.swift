import XCTest
@testable import BaseCampCore

final class NameCollisionTests: XCTestCase {
    private typealias Box = NameCollision.Box

    private let picture = Box(x: 0, y: 0, width: 400, height: 300)

    func testTheMoreImportantOfTwoOverlappingNamesIsKept() {
        let street = Box(x: 100, y: 100, width: 80, height: 14)
        let town = Box(x: 120, y: 105, width: 60, height: 16)

        XCTAssertEqual(NameCollision.kept([street, town], priorities: [120, 450], in: picture), [1])
    }

    func testNamesApartAreAllKept() {
        let a = Box(x: 10, y: 10, width: 50, height: 12)
        let b = Box(x: 10, y: 30, width: 50, height: 12)

        XCTAssertEqual(Set(NameCollision.kept([a, b], priorities: [80, 80], in: picture)), [0, 1])
    }

    func testANameCutByThePictureEdgeIsLeftOut() {
        let edge = Box(x: 370, y: 100, width: 60, height: 12)

        XCTAssertTrue(NameCollision.kept([edge], priorities: [900], in: picture).isEmpty)
    }

    func testNamesKeepClearOfTheLibrarysMarkers() {
        let name = Box(x: 100, y: 100, width: 80, height: 14)
        let waypoint = Box(x: 150, y: 95, width: 20, height: 20)

        XCTAssertTrue(NameCollision.kept([name], priorities: [990], in: picture, blocked: [waypoint]).isEmpty)
    }

    func testTiesKeepTheEarlierName() {
        let a = Box(x: 100, y: 100, width: 80, height: 14)
        let b = Box(x: 110, y: 102, width: 80, height: 14)

        XCTAssertEqual(NameCollision.kept([a, b], priorities: [100, 100], in: picture), [0])
        XCTAssertEqual(NameCollision.kept([b, a], priorities: [100, 100], in: picture), [0])
    }
}
