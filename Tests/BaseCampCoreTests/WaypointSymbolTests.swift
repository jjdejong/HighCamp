import XCTest
@testable import BaseCampCore

final class WaypointSymbolTests: XCTestCase {
    func testKnownSymbolsGetTheirSFSymbol() {
        XCTAssertEqual(WaypointSymbol.systemName(for: "Summit"), "mountain.2.fill")
        XCTAssertEqual(WaypointSymbol.systemName(for: "Food"), "fork.knife")
        XCTAssertEqual(WaypointSymbol.systemName(for: "Water Source"), "drop.fill")
    }

    func testLookupIgnoresCaseAndSurroundingSpaces() {
        XCTAssertEqual(WaypointSymbol.systemName(for: "  summit "), "mountain.2.fill")
    }

    func testUnknownSymbolGetsTheDefaultPin() {
        XCTAssertEqual(WaypointSymbol.systemName(for: "Something odd"), "mappin")
    }

    func testNoSymbolMeansNoGlyph() {
        XCTAssertNil(WaypointSymbol.systemName(for: nil))
        XCTAssertNil(WaypointSymbol.systemName(for: ""))
        XCTAssertNil(WaypointSymbol.systemName(for: "   "))
    }
}
