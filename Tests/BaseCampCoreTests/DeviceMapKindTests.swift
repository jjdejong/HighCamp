import XCTest
@testable import BaseCampCore

final class DeviceMapKindTests: XCTestCase {
    func testBuiltInMapsAreProtected() {
        XCTAssertEqual(DeviceMapKind.classify(name: "gmapbmap.img", siblings: []), .builtIn)
        XCTAssertEqual(DeviceMapKind.classify(name: "GMAPTZ.IMG", siblings: []), .builtIn)
        XCTAssertFalse(DeviceMapKind.builtIn.canDelete)
    }

    func testLicensedMapsAreProtected() {
        XCTAssertEqual(DeviceMapKind.classify(name: "D6185190A.img", siblings: []), .licensed)
        XCTAssertEqual(DeviceMapKind.classify(name: "D7557160A.img", siblings: ["d7557160a.gma"]), .licensed)
        XCTAssertFalse(DeviceMapKind.licensed.canDelete)
    }

    func testMapWithUnlockFileIsLicensedWhateverItsName() {
        XCTAssertEqual(DeviceMapKind.classify(name: "Atlas.img", siblings: ["atlas.gma"]), .licensed)
    }

    func testOrdinaryMapsCanBeDeleted() {
        XCTAssertEqual(DeviceMapKind.classify(name: "OFM(EU2026_SW).img", siblings: []), .custom)
        XCTAssertEqual(DeviceMapKind.classify(name: "d123.img", siblings: []), .custom)
        XCTAssertTrue(DeviceMapKind.custom.canDelete)
    }
}
