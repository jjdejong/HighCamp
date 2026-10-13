import XCTest
@testable import BaseCampCore

final class UndoHistoryTests: XCTestCase {
    func testEditUndoRedo() {
        var history = UndoHistory([1, 2, 3])
        history.edit("Add") { $0.append(4) }
        XCTAssertEqual(history.value, [1, 2, 3, 4])
        XCTAssertEqual(history.undoName, "Add")
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, [1, 2, 3])
        XCTAssertEqual(history.redoName, "Add")
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, [1, 2, 3, 4])
    }

    func testChangeThatDoesNothingIsNotAStep() {
        var history = UndoHistory("name")
        XCTAssertFalse(history.edit("Rename") { $0 = "name" })
        XCTAssertFalse(history.canUndo)
    }

    func testCoalescedEditsAreOneStep() {
        var history = UndoHistory("")
        for letter in ["B", "a", "s", "e"] {
            history.edit("Rename", coalesceKey: "name") { $0 += letter }
        }
        XCTAssertEqual(history.value, "Base")
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, "")
        XCTAssertFalse(history.canUndo)
    }

    func testDifferentKeysDoNotMerge() {
        var history = UndoHistory("")
        history.edit("Rename", coalesceKey: "a") { $0 += "x" }
        history.edit("Rename", coalesceKey: "b") { $0 += "y" }
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, "x")
    }

    func testNewEditClearsRedo() {
        var history = UndoHistory(0)
        history.edit("Up") { $0 += 1 }
        history.undo()
        XCTAssertTrue(history.canRedo)
        history.edit("Up") { $0 += 5 }
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.value, 5)
    }

    func testLimitDropsTheOldestSteps() {
        var history = UndoHistory(0, limit: 2)
        for _ in 0..<5 {
            history.edit("Up") { $0 += 1 }
        }
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.undo())
        XCTAssertFalse(history.undo())
        XCTAssertEqual(history.value, 3)
    }
}
