import AppKit
import BaseCampCore
import BaseCampIMG
import MapKit

/// A rendered picture, and how many of the tiles it was drawn from could not be loaded. Those stay blank.
struct RenderedMap {
    let image: NSImage
    var requestedTiles = 0
    var missingTiles = 0

    /// A message for the user when more than half the tiles are missing, otherwise nil.
    var missingTilesMessage: String? {
        guard requestedTiles > 0, missingTiles * 2 > requestedTiles else { return nil }
        return "\(missingTiles) of \(requestedTiles) map tiles could not be loaded, so those parts of the picture are blank."
    }
}

/// Saves the map as a picture: the base map for the visible area, with the coverage outlines, the lines and the
/// markers drawn on it. The Garmin maps are drawn from the map folder, as on screen. Apple's maps come from a
/// snapshot. Other base maps are drawn from their tiles, fetched from the same servers the map uses. The contour
/// tiles can be added on top of any base map but Apple's.
@MainActor
enum MapImageExport {
    /// Longest path, in points, that is drawn in full. Longer paths are thinned, so an export stays quick.
    static let maximumPointsPerPath = 2000
    /// The most points drawn for all the Garmin features together. Past this, every path is thinned further.
    static let maximumFeaturePoints = 400_000

    static func render(scene: MapScene, bounds: GeoBounds, size: CGSize, base: PictureBase) async throws -> RenderedMap {
        let projection = ImageProjection(bounds: bounds, size: size)
        if base.layer.isApple {
            return RenderedMap(image: try await renderSnapshot(scene: scene, projection: projection, base: base.layer))
        }
        return await renderTiles(scene: scene, projection: projection, base: base)
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

    /// A base map drawn in Web Mercator, the projection the tile servers use: the Garmin maps, or a tile server's tiles.
    private static func renderTiles(scene: MapScene, projection: ImageProjection, base picture: PictureBase) async -> RenderedMap {
        let base = picture.layer
        let contours = picture.contours
        // The contour tiles only go to zoom 16, so with them the base map is drawn at the same zoom.
        let zoom = projection.zoom(maximum: contours ? min(16, base.maximumTileZoom) : base.maximumTileZoom)
        let worldSize = 256 * pow(2, Double(zoom))
        let origin = projection.topLeftWorld(worldSize: worldSize)
        let scale = projection.size.width / projection.widthWorld(worldSize: worldSize)

        let columns = Int((origin.x / 256).rounded(.down))...Int(((origin.x + projection.size.width / scale - 0.001) / 256).rounded(.down))
        let rows = Int((origin.y / 256).rounded(.down))...Int(((origin.y + projection.size.height / scale - 0.001) / 256).rounded(.down))
        let baseTiles = base == .garmin
            ? FetchedTiles()
            : await fetchTiles(columns: columns, rows: rows) { base.tileURL(z: zoom, x: $0, y: $1) }
        let garmin = base == .garmin ? await garminFeatures(projection: projection, base: picture) : nil
        let contourTiles = contours
            ? await fetchTiles(columns: columns, rows: rows) { MapTileURLs.ignWMTS(layer: "ELEVATION.CONTOUR.LINE", z: zoom, x: $0, y: $1) }
            : FetchedTiles()

        let tileSize = 256 * scale
        func draw(_ tiles: [TileKey: NSImage], alpha: CGFloat) {
            for (key, image) in tiles {
                let at = NSPoint(x: (Double(key.column) * 256 - origin.x) * scale, y: (Double(key.row) * 256 - origin.y) * scale)
                // The picture is flipped (origin top left); without respectFlipped each tile would be drawn upside down.
                image.draw(
                    in: NSRect(origin: at, size: NSSize(width: tileSize, height: tileSize)), from: .zero,
                    operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil
                )
            }
        }
        let attribution = [base.attribution, contours ? MapTileURLs.contourAttribution : nil].compactMap { $0 }.joined(separator: " · ")

        let image = self.picture(size: projection.size) { rect in
            NSColor.white.setFill()
            rect.fill()
            if let garmin {
                GarminPainter.draw(garmin.features, in: rect, patternOrigin: .zero, step: garmin.step) { projection.point($0) }
            }
            draw(baseTiles.images, alpha: 1)
            draw(contourTiles.images, alpha: 0.8)
            drawOverlays(scene, projection: projection)
            drawAttribution(attribution, in: rect)
        }
        return RenderedMap(
            image: image,
            requestedTiles: baseTiles.requested + contourTiles.requested,
            missingTiles: baseTiles.missing + contourTiles.missing
        )
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

    /// The Garmin features for the picture's area, at the picture's scale, and how much to thin their paths so the
    /// total stays bounded.
    private static func garminFeatures(projection: ImageProjection, base: PictureBase) async -> (features: MapFeatureSet, step: Int) {
        let bounds = projection.bounds
        let middle = (bounds.north + bounds.south) / 2 * .pi / 180
        let metersPerPoint = 40_075_016.686 * cos(middle) * projection.widthWorld(worldSize: 1) / projection.size.width
        let features = await MapFeatureCache.shared.features(
            in: bounds, metersPerPoint: metersPerPoint, folder: base.garminFolder, detailOffset: base.garminDetail.offset
        )
        let points = features.lines.reduce(0) { $0 + $1.paths.reduce(0) { $0 + $1.count } }
            + features.areas.reduce(0) { $0 + $1.rings.reduce(0) { $0 + $1.count } }
        return (features, max(1, points / maximumFeaturePoints))
    }

    /// The coverage outlines, the lines, and the markers, in that order. Long lines are thinned.
    private static func drawOverlays(_ scene: MapScene, projection: ImageProjection) {
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
            path.lineWidth = CGFloat(line.width)
            path.lineJoinStyle = .round
            (line.rgb?.nsColor ?? line.color.nsColor).setStroke()
            path.stroke()
        }
        for pin in scene.pins {
            guard !isLabelOnly(pin.style) else { continue }
            let point = projection.point(pin.coordinate)
            // The same marker as the map, centred on the coordinate.
            let marker = MarkerImage.image(for: pin.style)
            marker.draw(
                in: NSRect(x: point.x - marker.size.width / 2, y: point.y - marker.size.height / 2, width: marker.size.width, height: marker.size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
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

    /// Downloads the tiles of a range, a few at a time. A tile that fails to load is left blank rather than ending
    /// the export, so the picture still comes out without a network.
    private static func fetchTiles(columns: ClosedRange<Int>, rows: ClosedRange<Int>, address: (Int, Int) -> URL?) async -> FetchedTiles {
        var keys: [(TileKey, URL)] = []
        for column in columns {
            for row in rows {
                if let url = address(column, row) {
                    keys.append((TileKey(column: column, row: row), url))
                }
            }
        }
        var fetched = FetchedTiles(requested: keys.count)
        var index = 0
        while index < keys.count {
            let batch = keys[index..<min(index + 8, keys.count)]
            index += 8
            await withTaskGroup(of: (TileKey, NSImage?).self) { group in
                for (key, url) in batch {
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.setValue("BaseCamp Clone/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
                        guard let loaded = try? await URLSession.shared.data(for: request),
                              (loaded.1 as? HTTPURLResponse)?.statusCode == 200 else { return (key, nil) }
                        return (key, NSImage(data: loaded.0))
                    }
                }
                for await (key, image) in group {
                    if let image {
                        fetched.images[key] = image
                    }
                }
            }
        }
        return fetched
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
}

/// The column and row of one map tile.
private struct TileKey: Hashable {
    let column: Int
    let row: Int
}

/// The tiles that were loaded, and how many were asked for. The difference is what stays blank.
private struct FetchedTiles {
    var images: [TileKey: NSImage] = [:]
    var requested = 0

    var missing: Int {
        requested - images.count
    }
}

/// Maps coordinates to a picture of a given size, in Web Mercator. The area is the requested bounds, made taller or
/// wider as needed so the picture is not stretched. Apple's snapshot is asked for the same area.
/// The picture's projection, for the app: the Mercator maths is in core, and this adds the AppKit and MapKit types.
private struct ImageProjection {
    private let projection: PictureProjection
    let size: CGSize

    init(bounds: GeoBounds, size: CGSize) {
        self.size = size
        projection = PictureProjection(
            north: bounds.north, east: bounds.east, south: bounds.south, west: bounds.west,
            width: size.width, height: size.height
        )
    }

    /// The area the picture covers, in degrees.
    var bounds: GeoBounds {
        GeoBounds(north: projection.north, east: projection.east, south: projection.south, west: projection.west)
    }

    /// The region for Apple's snapshot.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (projection.north + projection.south) / 2, longitude: (projection.east + projection.west) / 2),
            span: MKCoordinateSpan(latitudeDelta: projection.north - projection.south, longitudeDelta: projection.east - projection.west)
        )
    }

    /// The picture position of a coordinate, with the origin at the top left.
    func point(_ coordinate: Coordinate) -> NSPoint {
        let point = projection.point(coordinate)
        return NSPoint(x: point.x, y: point.y)
    }

    /// The zoom level at which one tile pixel is about one picture pixel, capped by `maximum`.
    func zoom(maximum: Int) -> Int {
        projection.zoom(maximum: maximum)
    }

    /// The top left corner of the area in world pixels at a given world size.
    func topLeftWorld(worldSize: Double) -> NSPoint {
        let corner = projection.topLeftWorld(worldSize: worldSize)
        return NSPoint(x: corner.x, y: corner.y)
    }

    /// The width of the area in world pixels.
    func widthWorld(worldSize: Double) -> Double {
        projection.widthWorld(worldSize: worldSize)
    }
}
