import AppKit
import BaseCampCore
import BaseCampIMG
import MapKit

/// The Garmin maps of the map list as the base map, drawn tile by tile from the maps themselves, the way
/// BaseCamp and QMapShack show them: areas, then road borders, then lines, map by map in the list's order.
final class GarminTileOverlay: MKTileOverlay {
    let configuration: GarminMapConfiguration

    init(configuration: GarminMapConfiguration) {
        self.configuration = configuration
        super.init(urlTemplate: nil)
        // Apple's map shows through where the Garmin maps have nothing to draw: zoomed far out, outside their
        // area, or when no map can be read, so the map is never blank (BaseCamp has its own world basemap there).
        canReplaceMapContent = false
        maximumZ = 21
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let configuration = configuration
        Task.detached(priority: .userInitiated) {
            let data = await GarminTileRenderer.png(
                z: path.z, x: path.x, y: path.y, scale: path.contentScaleFactor, configuration: configuration
            )
            result(data, nil)
        }
    }
}

/// The features of one map, ready to draw, with how the map is drawn.
struct GarminMapDrawing: Sendable {
    let features: MapFeatureSet
    let isOverlay: Bool
    let opacity: Double
    /// Drawn with softer colours: patterned areas filled plainly, everything paler. See `GarminPainter.draw`.
    var softColors = false
}

extension GarminMapConfiguration {
    /// The features of every map on at `zoom`, bottom first. Overlays use their finest level.
    func drawings(in area: GeoBounds, metersPerPoint: Double, zoom: Int) async -> [GarminMapDrawing] {
        var drawings: [GarminMapDrawing] = []
        for layer in layers where layer.isVisible(atZoom: zoom) {
            let features = await MapFeatureCache.shared.features(
                in: area, metersPerPoint: metersPerPoint, map: layer.url, finestLevel: layer.isOverlay, detailOffset: detailOffset
            )
            drawings.append(GarminMapDrawing(
                features: features, isOverlay: layer.isOverlay, opacity: layer.opacity,
                softColors: softColors && !layer.isOverlay
            ))
        }
        return drawings
    }
}

/// Draws one 256-point Web Mercator tile of the Garmin maps.
enum GarminTileRenderer {
    static let tileSize = 256.0

    static func png(z: Int, x: Int, y: Int, scale: CGFloat, configuration: GarminMapConfiguration) async -> Data? {
        let tiles = pow(2, Double(z))
        let bounds = GeoBounds(
            north: latitude(y: Double(y) / tiles),
            east: Double(x + 1) / tiles * 360 - 180,
            south: latitude(y: Double(y + 1) / tiles),
            west: Double(x) / tiles * 360 - 180
        )
        // Lines that cross the tile's edge start outside it, so read a little beyond it.
        let marginLatitude = (bounds.north - bounds.south) * 0.1
        let marginLongitude = (bounds.east - bounds.west) * 0.1
        let area = GeoBounds(
            north: bounds.north + marginLatitude, east: bounds.east + marginLongitude,
            south: bounds.south - marginLatitude, west: bounds.west - marginLongitude
        )
        let middle = (bounds.north + bounds.south) / 2 * .pi / 180
        let metersPerPoint = 40_075_016.686 * cos(middle) / (tileSize * tiles)
        let drawings = await configuration.drawings(in: area, metersPerPoint: metersPerPoint, zoom: z)
        // Shading only where a full map draws something, so it never darkens Apple's map on its own.
        let drawsMap = drawings.contains { !$0.isOverlay && !($0.features.lines.isEmpty && $0.features.areas.isEmpty) }
        let relief = drawsMap
            ? await GarminReliefRenderer.image(
                z: z, x: x, y: y, strength: configuration.relief,
                maps: configuration.layers.filter { $0.isVisible(atZoom: z) }.map(\.url)
            )
            : nil

        let worldSize = tileSize * tiles
        let origin = NSPoint(x: Double(x) * tileSize, y: Double(y) * tileSize)
        return render(size: tileSize, scale: max(1, scale)) { rect in
            GarminPainter.draw(drawings, in: rect, patternOrigin: origin, relief: relief) { coordinate in
                let world = WebMercator.unit(coordinate)
                return NSPoint(x: world.x * worldSize - origin.x, y: world.y * worldSize - origin.y)
            }
        }
    }

    /// A PNG of `size` points at `scale` pixels per point, drawn with the origin at the top left.
    private static func render(size: Double, scale: CGFloat, draw: (NSRect) -> Void) -> Data? {
        let pixels = Int((size * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: CGFloat(pixels))
        cg.scaleBy(x: scale, y: -scale)
        let context = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func latitude(y: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
    }
}

/// Web Mercator positions normalised to 0...1 across the world, origin at the top left.
enum WebMercator {
    static func unit(_ coordinate: Coordinate) -> (x: Double, y: Double) {
        let latitude = max(-85.0511, min(85.0511, coordinate.latitude)) * .pi / 180
        return ((coordinate.longitude + 180) / 360, (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2)
    }
}

/// Draws Garmin features into the current graphics context, which must be flipped (origin at the top left).
enum GarminPainter {
    /// Inside a map's coverage, where no area is filled.
    static let land = NSColor(calibratedRed: 0.976, green: 0.973, blue: 0.949, alpha: 1)
    /// With soft colours, how much white is laid over the full maps. Overlays, such as contours, stay as they are.
    static let softening = 0.35

    /// Draws the maps bottom first: land where a full map draws something, then each map's features, with its
    /// opacity. Elsewhere the picture stays transparent, so whatever is under it shows. A map whose level here holds
    /// nothing drawable (an overview level with only its background area, say) paints no land, so it cannot hide
    /// the map under it with a blank sheet. `patternOrigin` is the context origin's position in the pattern grid, so area patterns meet
    /// across tiles. `step` thins long paths for large pictures: every `step`-th point is drawn.
    static func draw(
        _ drawings: [GarminMapDrawing], in rect: NSRect, patternOrigin: NSPoint, step: Int = 1, relief: CGImage? = nil,
        project: (Coordinate) -> NSPoint
    ) {
        let context = NSGraphicsContext.current?.cgContext
        // Soft colours: the full maps are drawn in a layer, then paled with white where they drew something, the
        // way IGN's plan is drawn lighter than a road map. The layer is closed before the first overlay.
        var softening = drawings.contains { $0.softColors }
        if softening {
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        // The relief's shadows go over the full maps and under the overlays, so contours stay crisp.
        var shading = relief
        func endSoftening() {
            if softening {
                NSColor.white.withAlphaComponent(Self.softening).setFill()
                rect.fill(using: .sourceAtop)
                context?.endTransparencyLayer()
                softening = false
            }
            if let image = shading {
                context?.saveGState()
                context?.interpolationQuality = .high
                // The context is flipped; the picture is drawn upright into it.
                context?.translateBy(x: rect.minX, y: rect.maxY)
                context?.scaleBy(x: 1, y: -1)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                context?.restoreGState()
                shading = nil
            }
        }
        land.setFill()
        for drawing in drawings where !drawing.isOverlay && !(drawing.features.lines.isEmpty && drawing.features.areas.isEmpty) {
            for bounds in drawing.features.coverage {
                let corner = project(Coordinate(latitude: bounds.north, longitude: bounds.west))
                let opposite = project(Coordinate(latitude: bounds.south, longitude: bounds.east))
                NSRect(x: corner.x, y: corner.y, width: opposite.x - corner.x, height: opposite.y - corner.y).fill()
            }
        }
        NSGraphicsContext.current?.patternPhase = NSPoint(x: -patternOrigin.x, y: -patternOrigin.y)
        for drawing in drawings {
            if drawing.isOverlay {
                endSoftening()
            }
            let faded = drawing.opacity < 1
            if faded {
                context?.setAlpha(drawing.opacity)
                context?.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            draw(drawing.features, plainAreas: drawing.softColors, step: step, project: project)
            if faded {
                context?.endTransparencyLayer()
                context?.setAlpha(1)
            }
        }
        endSoftening()
    }

    /// One map's areas in the map's order, then its lines in two passes (see below). With `plainAreas`, patterned
    /// areas (forest drawn as rows of trees, say) are filled plainly, which makes the map much less busy.
    private static func draw(_ features: MapFeatureSet, plainAreas: Bool, step: Int, project: (Coordinate) -> NSPoint) {
        for group in features.areas {
            let path = NSBezierPath()
            for ring in group.rings {
                add(ring, to: path, closed: true, step: step, project: project)
            }
            (plainAreas ? plainColor(group.style) : fillColor(group.style)).setFill()
            path.fill()
        }

        let paths = features.lines.map { group in
            let path = NSBezierPath()
            for line in group.paths {
                add(line, to: path, closed: false, step: step, project: project)
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            return path
        }
        // As QMapShack draws them: first, type by type, each patterned line, or the border of a bordered line, or
        // a plain line; then the inside of every bordered line, so roads sit on top and join cleanly.
        for (group, path) in zip(features.lines, paths) {
            if group.style.pattern == nil, let border = group.style.border {
                border.nsColor.setStroke()
                path.lineWidth = group.style.borderWidth
                path.stroke()
            } else {
                stroke(path, style: group.style)
            }
        }
        for (group, path) in zip(features.lines, paths) where group.style.pattern == nil && group.style.border != nil {
            stroke(path, style: group.style)
        }
    }

    private static func stroke(_ path: NSBezierPath, style: LineStyle) {
        guard let pattern = style.pattern else {
            style.rgb.nsColor.setStroke()
            path.lineWidth = style.width
            path.stroke()
            return
        }
        // A pattern's rows run along the line, top row on one edge. It is drawn from the outside in, as nested
        // strokes: the outer rows at the full width, each next pair of rows two pixels narrower. Each stroke has
        // its row's background (or is cleared, inside a layer, when the background is transparent), then its set
        // pixels as dashes in the foreground colour. Patterns are taken as symmetric, as Garmin's mostly are.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        path.lineCapStyle = .butt
        for ring in 0..<((pattern.rows + 1) / 2) {
            path.lineWidth = CGFloat(pattern.rows - 2 * ring)
            path.setLineDash(nil, count: 0, phase: 0)
            if let background = style.background {
                background.nsColor.setStroke()
                path.stroke()
            } else if ring > 0 {
                context.setBlendMode(.clear)
                path.stroke()
                context.setBlendMode(.normal)
            }
            guard let dashes = dashes(row: ring, of: pattern) else { continue }
            style.rgb.nsColor.setStroke()
            path.setLineDash(dashes, count: dashes.count, phase: 0)
            path.stroke()
        }
        path.setLineDash(nil, count: 0, phase: 0)
        context.endTransparencyLayer()
    }

    /// Dash lengths for one row of a line pattern: on, off, on, ... Empty for a solid row, nil when no pixel is set.
    static func dashes(row: Int, of pattern: GarminTypStyle.Bitmap) -> [CGFloat]? {
        let columns = (0..<pattern.width).map { pattern.isSet(x: $0, y: row) }
        guard columns.contains(true) else { return nil }
        guard columns.contains(false) else { return [] }
        // Start at the first column that is set after an unset one, so the pattern begins with a dash.
        let start = (0..<columns.count).first { columns[$0] && !columns[($0 + columns.count - 1) % columns.count] } ?? 0
        var lengths: [CGFloat] = []
        var current = true
        var run: CGFloat = 0
        for offset in 0..<columns.count {
            let value = columns[(start + offset) % columns.count]
            if value == current {
                run += 1
            } else {
                lengths.append(run)
                current = value
                run = 1
            }
        }
        lengths.append(run)
        return lengths
    }

    private static func add(_ coordinates: [Coordinate], to path: NSBezierPath, closed: Bool, step: Int, project: (Coordinate) -> NSPoint) {
        guard let first = coordinates.first else { return }
        path.move(to: project(first))
        for index in Swift.stride(from: step, to: coordinates.count, by: step) {
            path.line(to: project(coordinates[index]))
        }
        if let last = coordinates.last, coordinates.count > 1, (coordinates.count - 1) % step != 0 {
            path.line(to: project(last))
        }
        if closed {
            path.close()
        }
    }

    // MARK: Area patterns

    private static let patternLock = NSLock()
    nonisolated(unsafe) private static var patterns: [AreaStyle: NSColor] = [:]

    /// A patterned area's plain fill: the pattern's average colour, so a forest drawn as trees stays forest green.
    /// Where the pattern's background is transparent, the colour is as transparent as the pattern is empty.
    private static func plainColor(_ style: AreaStyle) -> NSColor {
        guard let pattern = style.pattern, !pattern.bits.isEmpty else { return style.fill.nsColor }
        let set = CGFloat(pattern.bits.filter { $0 }.count) / CGFloat(pattern.bits.count)
        guard let background = style.background else {
            return style.fill.nsColor.withAlphaComponent(set)
        }
        return background.nsColor.blended(withFraction: set, of: style.fill.nsColor) ?? background.nsColor
    }

    /// The fill for an area: a plain colour, or its 32 by 32 pattern as a pattern colour, made once per style.
    private static func fillColor(_ style: AreaStyle) -> NSColor {
        guard let pattern = style.pattern else { return style.fill.nsColor }
        patternLock.lock()
        defer { patternLock.unlock() }
        if let cached = patterns[style] {
            return cached
        }
        let image = NSImage(size: NSSize(width: pattern.width, height: pattern.rows), flipped: true) { _ in
            if let background = style.background {
                background.nsColor.setFill()
                NSRect(x: 0, y: 0, width: pattern.width, height: pattern.rows).fill()
            }
            style.fill.nsColor.setFill()
            for y in 0..<pattern.rows {
                for x in 0..<pattern.width where pattern.isSet(x: x, y: y) {
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        let color = NSColor(patternImage: image)
        patterns[style] = color
        return color
    }
}
