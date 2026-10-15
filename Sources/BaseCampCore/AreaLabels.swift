import Foundation

/// A named area from a Garmin map: a lake, a forest, a park, a school. A large area often comes in several pieces,
/// cut at the map's cell edges, all with the same name.
public struct NamedArea: Sendable {
    public enum Kind: Sendable {
        case water, nature, other
    }

    public let name: String
    public let kind: Kind
    public let rings: [[Coordinate]]

    public init(name: String, kind: Kind, rings: [[Coordinate]]) {
        self.name = name
        self.kind = kind
        self.rings = rings
    }
}

/// A name already on the map, such as a town's, centred on `center`, `width` by `height` points.
public struct LabelBox: Sendable {
    public let center: Coordinate
    public let width: Double
    public let height: Double

    public init(center: Coordinate, width: Double, height: Double) {
        self.center = center
        self.width = width
        self.height = height
    }
}

/// Where an area's name is written.
public struct AreaLabel: Equatable, Sendable {
    public let name: String
    public let kind: NamedArea.Kind
    public let coordinate: Coordinate
    /// The area's size: log10 of its square metres in view. Larger areas win crowded spots.
    public let importance: Double
}

/// Places the names of areas, as a map writes them: inside the area, at the point furthest from its edges, once per
/// area, only when the area is big enough on screen to hold a name.
public enum AreaLabels {
    /// What an area of this Garmin type is, for the colour of its name, or nil when its name is not written:
    /// built-up areas (their towns are named), parking, buildings, the map's own outline, version 2 types. Types
    /// outside Garmin's list (OFM draws state forests with 0x23) are named too.
    public static func kind(of type: Int) -> NamedArea.Kind? {
        switch type {
        case 0x01...0x03, 0x05, 0x13, 0x4A, 0x4B, 0x10000...: return nil
        case 0x28, 0x29, 0x32, 0x3B...0x49, 0x4C: return .water
        case 0x14...0x17, 0x1E...0x21, 0x4D...0x53: return .nature
        default: return .other
        }
    }

    /// The kind an area's fill colour suggests: maps reuse some types (OFM draws rocks with a lake type), so a map's
    /// own style says better than the type whether the area is water.
    public static func kind(red: Int, green: Int, blue: Int) -> NamedArea.Kind {
        if blue > red + 25 && blue >= green { return .water }
        if green > red + 15 && green > blue + 15 { return .nature }
        return .other
    }

    /// Pieces of one name closer than this are one area.
    static let joinDistance = 1500.0
    /// The name needs this much room inside the area, in points from its anchor to the nearest edge.
    static let minimumDepth = 6.0
    /// And the area this many points across, or more for a long name: about three quarters of the name's width, on
    /// the two lines a name longer than 20 characters is written on.
    static func minimumWidth(for name: String) -> Double {
        let line = name.count > 20 ? (name.count + 1) / 2 : name.count
        return max(40, Double(line) * 4.5)
    }

    /// The names to write in the view, largest areas first. Each area is clipped to the view, so a large area partly
    /// in view is named in the part that shows. Names keep clear of `obstacles`, the town names that would hide them.
    public static func place(
        _ areas: [NamedArea], in view: (southWest: Coordinate, northEast: Coordinate), metersPerPoint: Double,
        avoiding obstacles: [LabelBox] = []
    ) -> [AreaLabel] {
        let plane = Plane(view)
        let boxes = obstacles.map { box -> Box in
            let centre = plane.point(box.center)
            let halfWidth = box.width / 2 * metersPerPoint, halfHeight = box.height / 2 * metersPerPoint
            return Box(minX: centre.x - halfWidth, maxX: centre.x + halfWidth, minY: centre.y - halfHeight, maxY: centre.y + halfHeight)
        }
        var labels: [AreaLabel] = []
        for area in areas {
            let pieces = area.rings.compactMap { ring -> Piece? in
                let clipped = plane.clip(ring.map(plane.point))
                return clipped.count >= 3 ? Piece(points: clipped) : nil
            }
            for cluster in clusters(pieces) {
                let largest = cluster.max { $0.area < $1.area }!
                guard largest.width / metersPerPoint >= minimumWidth(for: area.name) else { continue }
                let nearby = boxes.filter {
                    $0.maxX >= largest.minX && $0.minX <= largest.maxX && $0.maxY >= largest.minY && $0.minY <= largest.maxY
                }
                let (anchor, depth) = pole(of: largest.points, avoiding: nearby)
                guard depth / metersPerPoint >= minimumDepth else { continue }
                let total = cluster.reduce(0) { $0 + $1.area }
                labels.append(AreaLabel(
                    name: area.name, kind: area.kind, coordinate: plane.coordinate(anchor), importance: log10(max(total, 1))
                ))
            }
        }
        return labels.sorted { $0.importance > $1.importance }
    }

    /// Whether a coordinate is inside a ring (even-odd rule).
    public static func contains(_ ring: [Coordinate], _ coordinate: Coordinate) -> Bool {
        inside(ring.map { Point(x: $0.longitude, y: $0.latitude) }, Point(x: coordinate.longitude, y: coordinate.latitude))
    }

    // MARK: Geometry, in metres on a plane centred on the view

    struct Point {
        var x: Double
        var y: Double
    }

    private struct Box {
        let minX, maxX, minY, maxY: Double

        /// Distance from the box, negative inside it.
        func distance(_ p: Point) -> Double {
            let dx = max(minX - p.x, 0, p.x - maxX), dy = max(minY - p.y, 0, p.y - maxY)
            if dx == 0 && dy == 0 {
                return -min(p.x - minX, maxX - p.x, p.y - minY, maxY - p.y)
            }
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    private struct Piece {
        let points: [Point]
        let area: Double
        let minX: Double, maxX: Double, minY: Double, maxY: Double
        var width: Double { max(maxX - minX, maxY - minY) }

        init(points: [Point]) {
            self.points = points
            var sum = 0.0
            for (a, b) in zip(points, points.dropFirst() + [points[0]]) {
                sum += a.x * b.y - b.x * a.y
            }
            area = abs(sum) / 2
            minX = points.map(\.x).min()!
            maxX = points.map(\.x).max()!
            minY = points.map(\.y).min()!
            maxY = points.map(\.y).max()!
        }

        func gap(to other: Piece) -> Double {
            let dx = max(0, max(other.minX - maxX, minX - other.maxX))
            let dy = max(0, max(other.minY - maxY, minY - other.maxY))
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    private struct Plane {
        let latitude0: Double
        let longitude0: Double
        let metresPerDegreeLongitude: Double
        let metresPerDegreeLatitude = 111_132.0
        let minX: Double, maxX: Double, minY: Double, maxY: Double

        init(_ view: (southWest: Coordinate, northEast: Coordinate)) {
            latitude0 = (view.southWest.latitude + view.northEast.latitude) / 2
            longitude0 = (view.southWest.longitude + view.northEast.longitude) / 2
            metresPerDegreeLongitude = 111_320 * cos(latitude0 * .pi / 180)
            minX = (view.southWest.longitude - longitude0) * metresPerDegreeLongitude
            maxX = (view.northEast.longitude - longitude0) * metresPerDegreeLongitude
            minY = (view.southWest.latitude - latitude0) * metresPerDegreeLatitude
            maxY = (view.northEast.latitude - latitude0) * metresPerDegreeLatitude
        }

        func point(_ c: Coordinate) -> Point {
            Point(x: (c.longitude - longitude0) * metresPerDegreeLongitude, y: (c.latitude - latitude0) * metresPerDegreeLatitude)
        }

        func coordinate(_ p: Point) -> Coordinate {
            Coordinate(latitude: latitude0 + p.y / metresPerDegreeLatitude, longitude: longitude0 + p.x / metresPerDegreeLongitude)
        }

        /// Sutherland–Hodgman against the view's four edges.
        func clip(_ polygon: [Point]) -> [Point] {
            var result = polygon
            let edges: [(inside: (Point) -> Bool, cross: (Point, Point) -> Point)] = [
                ({ $0.x >= minX }, { a, b in Point(x: minX, y: a.y + (b.y - a.y) * (minX - a.x) / (b.x - a.x)) }),
                ({ $0.x <= maxX }, { a, b in Point(x: maxX, y: a.y + (b.y - a.y) * (maxX - a.x) / (b.x - a.x)) }),
                ({ $0.y >= minY }, { a, b in Point(x: a.x + (b.x - a.x) * (minY - a.y) / (b.y - a.y), y: minY) }),
                ({ $0.y <= maxY }, { a, b in Point(x: a.x + (b.x - a.x) * (maxY - a.y) / (b.y - a.y), y: maxY) }),
            ]
            for edge in edges {
                guard let last = result.last else { break }
                var output: [Point] = []
                var previous = last
                for current in result {
                    if edge.inside(current) {
                        if !edge.inside(previous) { output.append(edge.cross(previous, current)) }
                        output.append(current)
                    } else if edge.inside(previous) {
                        output.append(edge.cross(previous, current))
                    }
                    previous = current
                }
                result = output
            }
            return result
        }
    }

    /// Groups pieces that lie within `joinDistance` of each other, directly or through other pieces.
    private static func clusters(_ pieces: [Piece]) -> [[Piece]] {
        var group = Array(pieces.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while group[i] != i { i = group[i] }
            return i
        }
        for i in pieces.indices {
            for j in pieces.indices where j > i && pieces[i].gap(to: pieces[j]) < joinDistance {
                group[root(j)] = root(i)
            }
        }
        return Dictionary(grouping: pieces.indices, by: root).values.map { $0.map { pieces[$0] } }
    }

    /// The point inside the polygon furthest from its edges and from the boxes, and that distance: a grid over the
    /// polygon, then finer grids around the best point so far.
    private static func pole(of polygon: [Point], avoiding boxes: [Box]) -> (Point, Double) {
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        func depth(_ p: Point) -> Double {
            boxes.reduce(Self.depth(p, in: polygon)) { min($0, $1.distance(p)) }
        }
        var best = Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        var bestDepth = depth(best)
        var cell = max(maxX - minX, maxY - minY) / 16
        var centre = best
        var span = 8
        for _ in 0..<5 {
            for i in -span...span {
                for j in -span...span {
                    let candidate = Point(x: centre.x + Double(i) * cell, y: centre.y + Double(j) * cell)
                    let value = depth(candidate)
                    if value > bestDepth {
                        best = candidate
                        bestDepth = value
                    }
                }
            }
            centre = best
            cell /= 4
            span = 4
        }
        return (best, bestDepth)
    }

    /// Distance to the nearest edge, negative outside.
    private static func depth(_ p: Point, in polygon: [Point]) -> Double {
        var nearest = Double.infinity
        for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) {
            nearest = min(nearest, distance(p, a, b))
        }
        return inside(polygon, p) ? nearest : -nearest
    }

    private static func distance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return (x * x + y * y).squareRoot()
    }

    private static func inside(_ polygon: [Point], _ p: Point) -> Bool {
        var result = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                result.toggle()
            }
            j = i
        }
        return result
    }
}
