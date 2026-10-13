import Foundation

/// Places coordinates on a picture, in Web Mercator, the projection that map tiles use.
/// The picture shows the area it is given, grown where needed so that it is not stretched.
public struct PictureProjection {
    /// The area the picture covers, in degrees. It can be larger than the area that was asked for.
    public let north: Double
    public let east: Double
    public let south: Double
    public let west: Double
    /// The picture's size, in points.
    public let width: Double
    public let height: Double

    /// Mercator x and y, normalised to 0...1 across the world, for the edges of the picture.
    private let left: Double
    private let right: Double
    private let top: Double
    private let bottom: Double

    public init(north: Double, east: Double, south: Double, west: Double, width: Double, height: Double) {
        self.width = width
        self.height = height
        var left = Self.mercatorX(west)
        var right = Self.mercatorX(east)
        var top = Self.mercatorY(north)
        var bottom = Self.mercatorY(south)
        // Widen the area in whichever direction is too short for the picture's shape.
        let pictureAspect = width / height
        if (right - left) / (bottom - top) < pictureAspect {
            let extra = ((bottom - top) * pictureAspect - (right - left)) / 2
            left -= extra
            right += extra
        } else {
            let extra = ((right - left) / pictureAspect - (bottom - top)) / 2
            top -= extra
            bottom += extra
        }
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.north = Self.latitude(fromMercatorY: top)
        self.south = Self.latitude(fromMercatorY: bottom)
        self.east = Self.longitude(fromMercatorX: right)
        self.west = Self.longitude(fromMercatorX: left)
    }

    /// The picture position of a coordinate, with the origin at the top left, in points.
    public func point(_ coordinate: Coordinate) -> (x: Double, y: Double) {
        (
            (Self.mercatorX(coordinate.longitude) - left) / (right - left) * width,
            (Self.mercatorY(coordinate.latitude) - top) / (bottom - top) * height
        )
    }

    /// The zoom level at which one tile pixel is about one picture pixel, capped by `maximum`.
    public func zoom(maximum: Int) -> Int {
        let zoom = log2(width / (right - left) / 256)
        return min(maximum, max(1, Int(zoom.rounded())))
    }

    /// The top left corner of the area in world pixels at a given world size (256 times 2 to the zoom).
    public func topLeftWorld(worldSize: Double) -> (x: Double, y: Double) {
        (left * worldSize, top * worldSize)
    }

    /// The width of the area in world pixels.
    public func widthWorld(worldSize: Double) -> Double {
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

    private static func longitude(fromMercatorX x: Double) -> Double {
        x * 360 - 180
    }
}
