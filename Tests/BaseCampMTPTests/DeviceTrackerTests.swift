@testable import BaseCampMTP
import XCTest

final class DeviceTrackerTests: XCTestCase {
    private let edge = USBDeviceAddress(bus: 0, address: 29, vendorID: 0x091E, productID: 0x4F03)
    private let other = USBDeviceAddress(bus: 0, address: 31, vendorID: 0x091E, productID: 0x4F03)
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testADevicePresentAtStartIsOpenedAtOnce() {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: true, now: start)
        XCTAssertEqual(tracker.due(now: start)?.address, edge)
    }

    func testANewDeviceIsOpenedOnceItHasSettled() {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: false, now: start)
        XCTAssertNil(tracker.due(now: start + 2.9))
        XCTAssertEqual(tracker.nextAttempt(after: start), start + DeviceTracker.settleDelay)
        XCTAssertEqual(tracker.due(now: start + 3)?.address, edge)
    }

    func testADeviceThatLeavesBeforeSettlingIsNeverDue() {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: false, now: start)
        tracker.left(edge)
        XCTAssertNil(tracker.due(now: start + 10))
        XCTAssertNil(tracker.nextAttempt(after: start))
        XCTAssertTrue(tracker.isEmpty)
    }

    func testFailuresAreRetriedLessAndLessOftenThenGivenUp() throws {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: true, now: start)
        var now = start
        for delay in DeviceTracker.retryDelays {
            let due = try XCTUnwrap(tracker.due(now: now))
            XCTAssertFalse(tracker.failed(edge, serial: due.serial, now: now))
            XCTAssertNil(tracker.due(now: now + delay - 0.1))
            now += delay
        }
        let last = try XCTUnwrap(tracker.due(now: now))
        XCTAssertTrue(tracker.failed(edge, serial: last.serial, now: now))
        XCTAssertNil(tracker.due(now: now + 1000))
        XCTAssertFalse(tracker.isWaiting)

        tracker.retryGivenUp(now: now)
        XCTAssertEqual(tracker.due(now: now)?.address, edge)
    }

    func testRetryLeavesAnOpenedDeviceAlone() throws {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: true, now: start)
        let due = try XCTUnwrap(tracker.due(now: start))
        tracker.failed(edge, serial: due.serial, now: start)
        tracker.opened(edge, serial: due.serial)
        tracker.retryGivenUp(now: start + 10)
        XCTAssertNil(tracker.due(now: start + 10))
    }

    func testAReplugGetsANewSerialAndOldResultsAreIgnored() throws {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: true, now: start)
        let first = try XCTUnwrap(tracker.serial(of: edge))
        tracker.left(edge)
        tracker.arrived(edge, present: false, now: start + 1)
        let second = try XCTUnwrap(tracker.serial(of: edge))
        XCTAssertNotEqual(first, second)
        tracker.opened(edge, serial: first)
        XCTAssertEqual(tracker.due(now: start + 4)?.serial, second, "the earlier device's result does not count")
    }

    func testAPresentDeviceReportedAgainIsKeptOnce() {
        var tracker = DeviceTracker()
        tracker.arrived(edge, present: true, now: start)
        tracker.arrived(edge, present: false, now: start)
        tracker.arrived(other, present: false, now: start)
        XCTAssertEqual(tracker.plugged.map(\.address), [edge, other])
    }
}
