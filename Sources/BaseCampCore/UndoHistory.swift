import Foundation

/// Undo and redo for a value. Each change is one step. Changes that pass the same coalescing key in a row
/// (typing into one field) are merged into the first step, so one undo takes back the whole edit.
public struct UndoHistory<Value: Equatable> {
    public private(set) var value: Value

    private struct Step {
        var name: String
        var coalesceKey: String?
        var value: Value
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private let limit: Int

    public init(_ value: Value, limit: Int = 200) {
        self.value = value
        self.limit = limit
    }

    public var undoName: String? { undoSteps.last?.name }
    public var redoName: String? { redoSteps.last?.name }
    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    /// Applies a change as one undoable step. Returns false, and records nothing, when the change does nothing.
    @discardableResult
    public mutating func edit(_ name: String, coalesceKey: String? = nil, _ change: (inout Value) -> Void) -> Bool {
        var updated = value
        change(&updated)
        guard updated != value else { return false }
        if coalesceKey == nil || undoSteps.last?.coalesceKey != coalesceKey {
            undoSteps.append(Step(name: name, coalesceKey: coalesceKey, value: value))
            if undoSteps.count > limit {
                undoSteps.removeFirst()
            }
        }
        redoSteps.removeAll()
        value = updated
        return true
    }

    /// Takes back the last step. Returns false when there is nothing to undo.
    @discardableResult
    public mutating func undo() -> Bool {
        guard let step = undoSteps.popLast() else { return false }
        redoSteps.append(Step(name: step.name, coalesceKey: nil, value: value))
        value = step.value
        return true
    }

    /// Repeats the last undone step. Returns false when there is nothing to redo.
    @discardableResult
    public mutating func redo() -> Bool {
        guard let step = redoSteps.popLast() else { return false }
        undoSteps.append(Step(name: step.name, coalesceKey: nil, value: value))
        value = step.value
        return true
    }
}
