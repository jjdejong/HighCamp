import BaseCampCore
import XCTest

final class MapListTests: XCTestCase {
    private let folder: [(fileName: String, isOverlay: Bool)] = [
        ("OFM_SW.img", false), ("OFM_W.img", false), ("Utagawa.img", false), ("Isere_contours.img", true),
    ]

    func testOnlyTheFirstFullMapIsOnInANewList() {
        let list = MapList.synced([], with: folder)
        XCTAssertEqual(list.filter(\.isEnabled).map(\.fileName), ["OFM_SW.img"])
    }

    func testOverlaysGoOnTopOffAndCloseIn() {
        let list = MapList.synced([], with: folder)
        XCTAssertEqual(list.map(\.fileName), ["OFM_SW.img", "OFM_W.img", "Utagawa.img", "Isere_contours.img"])
        let contours = list[3]
        XCTAssertTrue(contours.isOverlay)
        XCTAssertFalse(contours.isEnabled)
        XCTAssertEqual(contours.minimumZoom, MapList.overlayMinimumZoom)
    }

    func testKnownMapsKeepTheirSettingsAndOrder() {
        var list = MapList.synced([], with: folder)
        list.swapAt(0, 2)
        list[3].isEnabled = true
        list[3].opacity = 0.5
        XCTAssertEqual(MapList.synced(list, with: folder), list)
    }

    func testRemovedMapsAreDroppedAndANewFullMapGoesBelowTheOverlays() {
        let list = MapList.synced([], with: folder)
        let after = MapList.synced(list, with: [("OFM_SW.img", false), ("Isere_contours.img", true), ("New.img", false)])
        XCTAssertEqual(after.map(\.fileName), ["OFM_SW.img", "New.img", "Isere_contours.img"])
        XCTAssertFalse(after[1].isEnabled, "a full map is already on")
    }

    func testANewFullMapIsOnWhenNoneIs() {
        let after = MapList.synced([], with: [("Isere_contours.img", true), ("New.img", false)])
        XCTAssertEqual(after.map(\.fileName), ["New.img", "Isere_contours.img"])
        XCTAssertTrue(after[0].isEnabled)
    }

    func testVisibilityFollowsTheZoomRangeAndOpacity() {
        var entry = MapListEntry(fileName: "a.img", isEnabled: true, isOverlay: true, minimumZoom: 13, maximumZoom: 21)
        XCTAssertFalse(entry.isVisible(atZoom: 12))
        XCTAssertTrue(entry.isVisible(atZoom: 13))
        entry.opacity = 0
        XCTAssertFalse(entry.isVisible(atZoom: 15))
    }

    func testEntriesSurviveACodableRoundTrip() throws {
        let list = MapList.synced([], with: folder)
        let decoded = try JSONDecoder().decode([MapListEntry].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(decoded, list)
    }
}
