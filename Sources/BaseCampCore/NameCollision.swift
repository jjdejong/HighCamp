import Foundation

/// Which names a picture writes, as the map does: of two names that would overlap, only the more important one.
public enum NameCollision {
    /// A name's box on the picture, in points.
    public struct Box: Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        func overlaps(_ other: Box) -> Bool {
            x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
        }

        func isInside(_ other: Box) -> Bool {
            x >= other.x && y >= other.y && x + width <= other.x + other.width && y + height <= other.y + other.height
        }
    }

    /// The indices of the names kept, most important first. A name is kept when it fits inside `bounds` and overlaps
    /// neither a name kept before it nor a `blocked` box (the library's markers). Ties keep the earlier name.
    public static func kept(_ boxes: [Box], priorities: [Float], in bounds: Box, blocked: [Box] = []) -> [Int] {
        precondition(boxes.count == priorities.count)
        let order = boxes.indices.sorted { priorities[$0] != priorities[$1] ? priorities[$0] > priorities[$1] : $0 < $1 }
        var taken = blocked
        var kept: [Int] = []
        for index in order {
            let box = boxes[index]
            guard box.isInside(bounds), !taken.contains(where: { $0.overlaps(box) }) else { continue }
            taken.append(box)
            kept.append(index)
        }
        return kept
    }
}
