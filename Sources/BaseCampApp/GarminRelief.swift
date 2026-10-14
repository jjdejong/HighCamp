import AppKit
import BaseCampCore
import BaseCampIMG

/// The heights the Garmin maps carry in their DEM parts, opened once per map and kept. Each map tile (subfile)
/// has its own DEM part, read when a picture first needs it.
actor MapReliefCache {
    static let shared = MapReliefCache()

    /// DEM parts kept in memory. One is a few hundred kilobytes.
    static let maximumParts = 96

    /// One map tile's heights and the area its finest grid covers.
    struct Part: Sendable {
        let dem: GarminDEM
        let bounds: GeoBounds
    }

    private struct OpenMap {
        let size: Int64
        let modified: Date?
        let image: GarminIMG
        /// Subfiles with a DEM part, and the area each one's map tile covers.
        let subfiles: [(name: String, bounds: GeoBounds)]
    }

    private struct PartKey: Hashable {
        let file: String
        let subfile: String
    }

    private var maps: [String: OpenMap] = [:]
    private var parts: [PartKey: Part?] = [:]
    private var partOrder: [PartKey] = []

    /// The DEM parts of the maps `urls` that reach into `area`, in the maps' order.
    func parts(in area: GeoBounds, maps urls: [URL]) -> [Part] {
        var found: [Part] = []
        for url in urls {
            guard let open = openMap(url) else { continue }
            for subfile in open.subfiles where MapFeatureReader.intersects(subfile.bounds, area) {
                guard !Task.isCancelled else { return [] }
                if let part = part(PartKey(file: url.path, subfile: subfile.name), image: open.image) {
                    found.append(part)
                }
            }
        }
        return found
    }

    private func part(_ key: PartKey, image: GarminIMG) -> Part? {
        if let cached = parts[key] {
            return cached
        }
        var part: Part?
        if let dem = try? image.dem(of: key.subfile), let finest = dem.levels.min(by: { $0.pixelWidth < $1.pixelWidth }) {
            part = Part(dem: dem, bounds: GeoBounds(north: finest.north, east: finest.east, south: finest.south, west: finest.west))
        }
        parts[key] = .some(part)
        partOrder.append(key)
        if partOrder.count > Self.maximumParts {
            parts[partOrder.removeFirst()] = nil
        }
        return part
    }

    private func openMap(_ url: URL) -> OpenMap? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        if let cached = maps[url.path], cached.size == size, cached.modified == modified {
            return cached
        }
        guard let image = try? GarminIMG(url: url) else {
            maps[url.path] = nil
            return nil
        }
        let subfiles = image.subfiles.compactMap { subfile -> (String, GeoBounds)? in
            guard subfile.parts.contains("DEM"), let bounds = subfile.bounds else { return nil }
            return (subfile.name, bounds)
        }
        let open = OpenMap(size: size, modified: modified, image: image, subfiles: subfiles)
        maps[url.path] = open
        parts = parts.filter { $0.key.file != url.path }
        partOrder.removeAll { $0.file == url.path }
        return open
    }
}

/// Draws the relief shading of one Web Mercator tile from the Garmin maps' heights.
enum GarminReliefRenderer {
    /// Heights are taken on a grid this many points across the tile, then the shadows are drawn stretched to it.
    static let grid = 128
    /// Smoothing, in grid points. A coarse height grid would otherwise show its pixels as facets.
    static let blur = 2
    /// Not drawn further out: a tile would need too many map tiles' heights.
    static let minimumZoom = 8

    /// The shadows for tile `x`, `y` at zoom `z`, as a picture to draw over the tile, or nil where the maps have
    /// no heights.
    static func image(z: Int, x: Int, y: Int, strength: Double, maps: [URL]) async -> CGImage? {
        guard strength > 0, z >= minimumZoom, !maps.isEmpty else { return nil }
        let tiles = pow(2, Double(z))
        let extend = blur + 1
        let size = grid + 2 * extend
        // The grid points, from the north-west, half a step in from the tile's corner.
        func longitude(_ i: Int) -> Double {
            (Double(x) + (Double(i - extend) + 0.5) / Double(grid)) / tiles * 360 - 180
        }
        func latitude(_ j: Int) -> Double {
            let unit = (Double(y) + (Double(j - extend) + 0.5) / Double(grid)) / tiles
            return atan(sinh(.pi * (1 - 2 * unit))) * 180 / .pi
        }
        let area = GeoBounds(north: latitude(0), east: longitude(size - 1), south: latitude(size - 1), west: longitude(0))
        let parts = await MapReliefCache.shared.parts(in: area, maps: maps)
        guard !parts.isEmpty, !Task.isCancelled else { return nil }

        let degreesPerPoint = (area.east - area.west) / Double(size)
        let latitudes = (0..<size).map(latitude)
        let longitudes = (0..<size).map(longitude)
        var heights = [Double](repeating: .nan, count: size * size)
        for part in parts {
            guard !Task.isCancelled else { return nil }
            if let level = part.dem.level(forDegreesPerPixel: degreesPerPoint) {
                part.dem.fill(&heights, latitudes: latitudes, longitudes: longitudes, level: level)
            }
        }
        let found = heights.contains { !$0.isNaN }
        guard found, !Task.isCancelled else { return nil }

        let middle = (area.north + area.south) / 2 * .pi / 180
        let spacing = 40_075_016.686 * cos(middle) / (Double(grid) * tiles)
        let smooth = ReliefShading.blurred(heights, width: size, height: size, radius: blur)
        // The blur's own margin is cut off here; the slope needs one more point on each side.
        let inner = grid + 2
        var cropped = [Double](repeating: .nan, count: inner * inner)
        for j in 0..<inner {
            for i in 0..<inner {
                cropped[j * inner + i] = smooth[(j + blur) * size + (i + blur)]
            }
        }
        let shadows = ReliefShading(strength: strength).shadows(
            heights: cropped, width: inner, height: inner, spacing: spacing,
            exaggeration: ReliefShading.exaggeration(spacing: spacing)
        )
        return picture(shadows, size: grid)
    }

    /// Black, with each point's shadow as its alpha.
    private static func picture(_ shadows: [UInt8], size: Int) -> CGImage? {
        guard shadows.count == size * size else { return nil }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for (index, alpha) in shadows.enumerated() {
            pixels[index * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
