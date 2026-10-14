import Foundation

/// A street or river name placed along its line.
public struct StreetLabel: Equatable, Sendable {
    public let name: String
    public let coordinate: Coordinate
    /// The line's direction on a north-up map, in radians counterclockwise from east, between -π/2 and π/2, so the
    /// text never reads upside down.
    public let angle: Double
    /// Bigger roads are more important; MapKit keeps the more important of two names that would overlap.
    public let importance: Int
    public let isWater: Bool

    public init(name: String, coordinate: Coordinate, angle: Double, importance: Int, isWater: Bool) {
        self.name = name
        self.coordinate = coordinate
        self.angle = angle
        self.importance = importance
        self.isWater = isWater
    }
}

/// A named line from a map, as the map stores it: a street may be cut into many pieces.
public struct NamedLine: Sendable {
    public let name: String
    public let coordinates: [Coordinate]
    public let importance: Int
    public let isWater: Bool

    public init(name: String, coordinates: [Coordinate], importance: Int, isWater: Bool) {
        self.name = name
        self.coordinates = coordinates
        self.importance = importance
        self.isWater = isWater
    }
}

public enum StreetLabels {
    /// The width of one character of a name, in points, roughly, for the label size used on the map.
    public static let characterWidth = 6.2

    /// Where to write the names of `lines` on a map of `metersPerPoint`: the pieces of a street are joined end to
    /// end, a name goes in the middle of each stretch long enough to hold it, and again every so often along long
    /// ones. Each name is turned to follow its line around it.
    public static func place(_ lines: [NamedLine], metersPerPoint: Double) -> [StreetLabel] {
        var labels: [StreetLabel] = []
        let groups = Dictionary(grouping: lines.filter { $0.coordinates.count > 1 }) { $0.name }
        for (name, pieces) in groups {
            let text = (Double(name.count) * characterWidth + 12) * metersPerPoint
            let spacing = max(text * 3, 500 * metersPerPoint)
            var kept: [Coordinate] = []
            for chain in joined(pieces.map(\.coordinates)).sorted(by: { length($0) > length($1) }) {
                let total = length(chain)
                guard total >= text * 1.1 else { continue }
                let count = max(1, Int(total / spacing))
                for index in 0..<count {
                    let middle = total * (Double(index) + 0.5) / Double(count)
                    guard let place = point(on: chain, at: middle),
                          let before = point(on: chain, at: max(0, middle - text / 2)),
                          let after = point(on: chain, at: min(total, middle + text / 2)) else { continue }
                    // A name is not repeated close to another of the same street.
                    guard !kept.contains(where: { Geodesy.distance(from: $0, to: place) < spacing * 0.8 }) else { continue }
                    kept.append(place)
                    let first = pieces[0]
                    labels.append(StreetLabel(
                        name: name, coordinate: place, angle: angle(from: before, to: after),
                        importance: pieces.map(\.importance).max() ?? first.importance, isWater: first.isWater
                    ))
                }
            }
        }
        return labels.sorted { ($0.importance, $1.name) > ($1.importance, $0.name) }
    }

    /// Pieces joined where one ends at another's start or end, as a street is stored in pieces between crossings.
    /// A piece that would turn the line back on itself is not joined: the two halves of a dual carriageway meet at
    /// their ends, and joined they would make a hairpin whose middle lies across the road.
    static func joined(_ pieces: [[Coordinate]]) -> [[Coordinate]] {
        var chains: [[Coordinate]] = []
        var remaining = pieces
        while var chain = remaining.popLast() {
            var grew = true
            while grew {
                grew = false
                for (index, piece) in remaining.enumerated() {
                    guard let first = piece.first, let last = piece.last, let start = chain.first, let end = chain.last else { continue }
                    let reversed = Array(piece.reversed())
                    if same(first, end), continues(chain, into: piece) {
                        chain += piece.dropFirst()
                    } else if same(last, end), continues(chain, into: reversed) {
                        chain += reversed.dropFirst()
                    } else if same(last, start), continues(piece, into: chain) {
                        chain = piece + chain.dropFirst()
                    } else if same(first, start), continues(reversed, into: chain) {
                        chain = reversed + chain.dropFirst()
                    } else {
                        continue
                    }
                    remaining.remove(at: index)
                    grew = true
                    break
                }
            }
            chains.append(chain)
        }
        return chains
    }

    /// Whether `next`, which starts where `line` ends, carries on rather than turning back (a turn under 120°).
    private static func continues(_ line: [Coordinate], into next: [Coordinate]) -> Bool {
        guard line.count > 1, next.count > 1 else { return true }
        func direction(_ a: Coordinate, _ b: Coordinate) -> (Double, Double) {
            ((b.longitude - a.longitude) * cos(a.latitude * .pi / 180), b.latitude - a.latitude)
        }
        let a = direction(line[line.count - 2], line[line.count - 1])
        let b = direction(next[0], next[1])
        let lengths = (a.0 * a.0 + a.1 * a.1).squareRoot() * (b.0 * b.0 + b.1 * b.1).squareRoot()
        guard lengths > 0 else { return true }
        return (a.0 * b.0 + a.1 * b.1) / lengths > -0.5
    }

    private static func same(_ a: Coordinate, _ b: Coordinate) -> Bool {
        abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
    }

    static func length(_ line: [Coordinate]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + Geodesy.distance(from: $1.0, to: $1.1) }
    }

    /// The place `distance` metres along `line`.
    static func point(on line: [Coordinate], at distance: Double) -> Coordinate? {
        var travelled = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let step = Geodesy.distance(from: a, to: b)
            if travelled + step >= distance, step > 0 {
                let t = (distance - travelled) / step
                return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            travelled += step
        }
        return line.last
    }

    /// The direction from `a` to `b` on a north-up Mercator map, kept between -π/2 and π/2.
    static func angle(from a: Coordinate, to b: Coordinate) -> Double {
        let east = (b.longitude - a.longitude) * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let north = b.latitude - a.latitude
        var angle = atan2(north, east)
        if angle > .pi / 2 {
            angle -= .pi
        } else if angle <= -.pi / 2 {
            angle += .pi
        }
        return angle
    }
}
