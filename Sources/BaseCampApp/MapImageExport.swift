import AppKit
import BaseCampCore
import BaseCampIMG
import MapKit

/// Saves the map as a picture: the base map for the visible area, with the Garmin features, the coverage outlines,
/// the lines and the markers drawn on it. Apple's maps come from a snapshot. Other base maps are drawn from their
/// tiles, which are fetched from the same servers the map uses. The contour tiles can be added on top.
@MainActor
enum MapImageExport {
    /// Longest path, in points, that is drawn in full. Longer paths are thinned, so an export stays quick.
    static let maximumPointsPerPath = 2000
    /// The most points drawn for all the Garmin features together. Past this, every path is thinned further.
    static let maximumFeaturePoints = 400_000

    static func render(scene: MapScene, bounds: GeoBounds, size: CGSize, base: BaseMapLayer, contours: Bool = false) async throws -> NSImage {
        let projection = ImageProjection(bounds: bounds, size: size)
        if base.tileURL(z: 0, x: 0, y: 0) == nil {
            return try await renderSnapshot(scene: scene, projection: projection, base: base)
        }
        return try await renderTiles(scene: scene, projection: projection, base: base, contours: contours)
    }

    /// Apple's own map, drawn by MapKit over the same area the projection covers.
    private static func renderSnapshot(scene: MapScene, projection: ImageProjection, base: BaseMapLayer) async throws -> NSImage {
        let options = MKMapSnapshotter.Options()
        options.region = projection.region
        options.size = projection.size
        options.mapType = base == .appleHybrid ? .hybrid : .standard
        let snapshot = try await MKMapSnapshotter(options: options).start()
        return picture(size: projection.size) { rect in
            snapshot.image.draw(in: rect)
            drawOverlays(scene, projection: projection)
        }
    }

    /// A base map drawn from tiles in Web Mercator, the projection the tile servers use.
    private static func renderTiles(scene: MapScene, projection: ImageProjection, base: BaseMapLayer, contours: Bool) async throws -> NSImage {
        // The contour tiles only go to zoom 16, so with them the base map is drawn at the same zoom.
        let zoom = projection.zoom(maximum: contours ? min(16, base.maximumTileZoom) : base.maximumTileZoom)
        let worldSize = 256 * pow(2, Double(zoom))
        let origin = projection.topLeftWorld(worldSize: worldSize)
        let scale = projection.size.width / projection.widthWorld(worldSize: worldSize)

        let columns = Int((origin.x / 256).rounded(.down))...Int(((origin.x + projection.size.width / scale - 0.001) / 256).rounded(.down))
        let rows = Int((origin.y / 256).rounded(.down))...Int(((origin.y + projection.size.height / scale - 0.001) / 256).rounded(.down))
        let baseTiles = try await fetchTiles(columns: columns, rows: rows) { base.tileURL(z: zoom, x: $0, y: $1) }
        let contourTiles = contours
            ? try await fetchTiles(columns: columns, rows: rows) { MapTileURLs.ignWMTS(layer: "ELEVATION.CONTOUR.LINE", z: zoom, x: $0, y: $1) }
            : [:]

        let tileSize = 256 * scale
        func draw(_ tiles: [TileKey: NSImage], alpha: CGFloat) {
            for (key, image) in tiles {
                let at = NSPoint(x: (Double(key.column) * 256 - origin.x) * scale, y: (Double(key.row) * 256 - origin.y) * scale)
                image.draw(in: NSRect(origin: at, size: NSSize(width: tileSize, height: tileSize)), from: .zero, operation: .sourceOver, fraction: alpha)
            }
        }
        let attribution = [base.attribution, contours ? MapTileURLs.contourAttribution : nil].compactMap { $0 }.joined(separator: " · ")

        return picture(size: projection.size) { rect in
            NSColor.white.setFill()
            rect.fill()
            draw(baseTiles, alpha: 1)
            draw(contourTiles, alpha: 0.8)
            drawOverlays(scene, projection: projection)
            drawAttribution(attribution, in: rect)
        }
    }

    /// Draws a picture once, with the origin at the top left. The drawing is made into a bitmap straight away, so
    /// the work is not repeated each time the picture is converted for saving.
    private static func picture(size: CGSize, draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        draw(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    /// The Garmin areas and lines, the coverage outlines, the other lines, and the markers, in that order.
    /// Only what is inside the picture is drawn, and long lines are thinned.
    private static func drawOverlays(_ scene: MapScene, projection: ImageProjection) {
        let view = projection.bounds
        // Spread the point budget over all the features in the picture, so the total stays bounded.
        let featurePoints = (scene.featureLayer?.lines ?? []).reduce(0) { total, group in
            total + group.paths.reduce(0) { $0 + ($1.count > 1 && overlaps($1, view) ? $1.count : 0) }
        } + (scene.featureLayer?.areas ?? []).reduce(0) { total, group in
            total + group.rings.reduce(0) { $0 + ($1.count >= 3 && overlaps($1, view) ? $1.count : 0) }
        }
        let globalStep = max(1, featurePoints / maximumFeaturePoints)
        for group in scene.featureLayer?.areas ?? [] {
            let path = NSBezierPath()
            for ring in group.rings where ring.count >= 3 && overlaps(ring, view) {
                addPath(ring, to: path, projection: projection, closed: true, minimumStep: globalStep)
            }
            group.fill.nsColor.withAlphaComponent(0.7).setFill()
            path.fill()
        }
        for group in scene.featureLayer?.lines ?? [] {
            let path = NSBezierPath()
            for line in group.paths where line.count > 1 && overlaps(line, view) {
                addPath(line, to: path, projection: projection, closed: false, minimumStep: globalStep)
            }
            path.lineWidth = CGFloat(group.width)
            path.lineJoinStyle = .round
            group.rgb.nsColor.setStroke()
            path.stroke()
        }
        for footprint in scene.footprints {
            let path = NSBezierPath()
            addPath(footprint.corners, to: path, projection: projection, closed: true)
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemPurple.setStroke()
            path.stroke()
        }
        for line in scene.lines where line.coordinates.count > 1 {
            let path = NSBezierPath()
            addPath(line.coordinates, to: path, projection: projection, closed: false)
            path.lineWidth = 3
            path.lineJoinStyle = .round
            line.color.nsColor.setStroke()
            path.stroke()
        }
        for pin in scene.pins {
            guard !isLabelOnly(pin.style) else { continue }
            let point = projection.point(pin.coordinate)
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            markerColor(pin.style).setFill()
            NSColor.white.setStroke()
            dot.lineWidth = 1.5
            dot.fill()
            dot.stroke()
        }
    }

    /// Adds one path, thinned to about `maximumPointsPerPath` points. Each path starts with a move, so it is not joined
    /// to the path added before it. The last point is always kept.
    private static func addPath(_ coordinates: [Coordinate], to path: NSBezierPath, projection: ImageProjection, closed: Bool, minimumStep: Int = 1) {
        guard let first = coordinates.first else { return }
        let step = max(minimumStep, coordinates.count / maximumPointsPerPath)
        path.move(to: projection.point(first))
        for index in Swift.stride(from: step, to: coordinates.count, by: step) {
            path.line(to: projection.point(coordinates[index]))
        }
        if let last = coordinates.last, (coordinates.count - 1) % step != 0 {
            path.line(to: projection.point(last))
        }
        if closed {
            path.close()
        }
    }

    /// Whether any point of a path is inside the area, judged by the path's bounding box.
    private static func overlaps(_ coordinates: [Coordinate], _ area: GeoBounds) -> Bool {
        var north = -Double.infinity, south = Double.infinity, east = -Double.infinity, west = Double.infinity
        for coordinate in coordinates {
            north = max(north, coordinate.latitude)
            south = min(south, coordinate.latitude)
            east = max(east, coordinate.longitude)
            west = min(west, coordinate.longitude)
        }
        return south <= area.north && north >= area.south && west <= area.east && east >= area.west
    }

    /// Downloads the tiles of a range, a few at a time.
    private static func fetchTiles(columns: ClosedRange<Int>, rows: ClosedRange<Int>, address: (Int, Int) -> URL?) async throws -> [TileKey: NSImage] {
        var keys: [(TileKey, URL)] = []
        for column in columns {
            for row in rows {
                if let url = address(column, row) {
                    keys.append((TileKey(column: column, row: row), url))
                }
            }
        }
        var result: [TileKey: NSImage] = [:]
        var index = 0
        while index < keys.count {
            let batch = keys[index..<min(index + 8, keys.count)]
            index += 8
            try await withThrowingTaskGroup(of: (TileKey, NSImage?).self) { group in
                for (key, url) in batch {
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.setValue("BaseCamp Clone/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return (key, nil) }
                        return (key, NSImage(data: data))
                    }
                }
                for try await (key, image) in group {
                    if let image {
                        result[key] = image
                    }
                }
            }
        }
        return result
    }

    private static func drawAttribution(_ text: String, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(x: 6, y: rect.height - size.height - 10, width: size.width + 10, height: size.height + 4)
        NSColor.windowBackgroundColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attributes)
    }

    /// The PNG data of an image.
    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func isLabelOnly(_ style: MapPin.Style) -> Bool {
        if case .label = style { return true }
        return false
    }

    private static func markerColor(_ style: MapPin.Style) -> NSColor {
        switch style {
        case .waypoint(let selected): selected ? .systemRed : .systemBlue
        case .via: .systemGreen
        case .steep: .systemOrange
        case .label: .systemPurple
        case .cursor: .systemRed
        case .routePoint: .systemBlue
        }
    }
}

/// The column and row of one map tile.
private struct TileKey: Hashable {
    let column: Int
    let row: Int
}

/// Maps coordinates to a picture of a given size, in Web Mercator. The area is the requested bounds, made taller or
/// wider as needed so the picture is not stretched. Apple's snapshot is asked for the same area.
private struct ImageProjection {
    /// The area the picture covers, in degrees.
    let bounds: GeoBounds
    let size: CGSize
    /// Mercator x and y, normalised to 0...1 across the world, for the edges of the picture.
    private let left: Double
    private let right: Double
    private let top: Double
    private let bottom: Double

    init(bounds: GeoBounds, size: CGSize) {
        self.size = size
        let left = Self.mercatorX(bounds.west)
        let right = Self.mercatorX(bounds.east)
        var top = Self.mercatorY(bounds.north)
        var bottom = Self.mercatorY(bounds.south)
        // Widen the area in the direction that is too short for the picture's shape.
        let neededHeight = (right - left) * Double(size.height / size.width)
        let extra = (neededHeight - (bottom - top)) / 2
        if extra > 0 {
            top -= extra
            bottom += extra
        }
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.bounds = GeoBounds(
            north: Self.latitude(fromMercatorY: top),
            east: bounds.east,
            south: Self.latitude(fromMercatorY: bottom),
            west: bounds.west
        )
    }

    /// The region for Apple's snapshot.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (bounds.north + bounds.south) / 2, longitude: (bounds.east + bounds.west) / 2),
            span: MKCoordinateSpan(latitudeDelta: bounds.north - bounds.south, longitudeDelta: bounds.east - bounds.west)
        )
    }

    /// The picture position of a coordinate, with the origin at the top left.
    func point(_ coordinate: Coordinate) -> NSPoint {
        NSPoint(
            x: (Self.mercatorX(coordinate.longitude) - left) / (right - left) * size.width,
            y: (Self.mercatorY(coordinate.latitude) - top) / (bottom - top) * size.height
        )
    }

    /// The zoom level at which one tile pixel is about one picture pixel, capped by `maximum`.
    func zoom(maximum: Int) -> Int {
        let zoom = log2(Double(size.width) / (right - left) / 256)
        return min(maximum, max(1, Int(zoom.rounded())))
    }

    /// The top left corner of the area in world pixels at a given world size (256 times 2 to the zoom).
    func topLeftWorld(worldSize: Double) -> NSPoint {
        NSPoint(x: left * worldSize, y: top * worldSize)
    }

    /// The width of the area in world pixels.
    func widthWorld(worldSize: Double) -> Double {
        (right - left) * worldSize
    }

    private static func mercatorX(_ longitude: Double) -> Double {
        (longitude + 180) / 360
    }

    private static func mercatorY(_ latitude: Double) -> Double {
        let clamped = max(-85.0511, min(85.0511, latitude)) * .pi / 180
        return (1 - log(tan(clamped) + 1 / cos(clamped)) / .pi) / 2
    }

    private static func latitude(fromMercatorY y: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
    }
}
