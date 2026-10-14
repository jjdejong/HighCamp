import Foundation

/// Hill shading: how much shadow each point of a height grid gets, lit from the north-west as maps are. The
/// shadow is drawn as black with this alpha over the map, so flat ground stays almost untouched and slopes facing
/// away from the light darken. Follows GPXSee's hillshading (Horn's slope, Lambert lighting), with slopes in true
/// metres, so the look is the same at every zoom, and an exaggeration that grows as the map zooms out.
public struct ReliefShading: Sendable {
    /// The strongest shadow, 0...1.
    public var strength: Double
    public var azimuth: Double = 315
    public var altitude: Double = 45
    /// Lifts the darkest shadows, 0...1.
    public var lightening: Double = 0.2

    public init(strength: Double) {
        self.strength = strength
    }

    /// The shadow alpha (0...255) for each inner point of `heights`, a grid of `width` by `height` points spaced
    /// `spacing` metres apart, row by row from the north. The outer ring of points only feeds the slopes, so the
    /// result is `(width - 2) * (height - 2)` values. A point next to one without a height (NaN) gets none.
    public func shadows(heights: [Double], width: Int, height: Int, spacing: Double, exaggeration: Double) -> [UInt8] {
        guard width > 2, height > 2, heights.count == width * height, spacing > 0 else { return [] }
        let a = azimuth * .pi / 180
        let b = altitude * .pi / 180
        let a1 = sin(b), a2 = cos(b) * sin(a), a3 = cos(b) * cos(a)
        let scale = exaggeration / (8 * spacing)
        let full = strength * 255
        var result = [UInt8](repeating: 0, count: (width - 2) * (height - 2))
        var index = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                defer { index += 1 }
                let top = (y - 1) * width + x, middle = y * width + x, bottom = (y + 1) * width + x
                let z1 = heights[top - 1], z2 = heights[top], z3 = heights[top + 1]
                let z4 = heights[middle - 1], z6 = heights[middle + 1]
                let z7 = heights[bottom - 1], z8 = heights[bottom], z9 = heights[bottom + 1]
                // East minus west, and north minus south: the slope's two parts.
                let dzdx = scale * (z3 + 2 * z6 + z9 - z1 - 2 * z4 - z7)
                let dzdy = scale * (z1 + 2 * z2 + z3 - z7 - 2 * z8 - z9)
                var light = (a1 - a2 * dzdx - a3 * dzdy) / (1 + dzdx * dzdx + dzdy * dzdy).squareRoot()
                guard light.isFinite else { continue }
                light = max(light, 0) * (1 - lightening) + lightening
                light = light.squareRoot()
                result[index] = UInt8(max(0, min(255, (full * (1 - light)).rounded())))
            }
        }
        return result
    }

    /// How much steeper than true the slopes are drawn when `spacing` metres separate the points. Zoomed out, true
    /// slopes average away and the relief would vanish, so they are steepened more as the spacing grows.
    public static func exaggeration(spacing: Double) -> Double {
        min(max(spacing.squareRoot() * 0.9, 1.5), 12)
    }

    /// A box blur of `radius` points, which smooths the steps a coarse height grid leaves between its pixels.
    /// Points without a height stay without one and are left out of their neighbours' means.
    public static func blurred(_ heights: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        guard radius > 0, width > 0, height > 0 else { return heights }
        func pass(_ source: [Double], horizontal: Bool) -> [Double] {
            var output = source
            let lines = horizontal ? height : width
            let length = horizontal ? width : height
            for line in 0..<lines {
                func at(_ i: Int) -> Int { horizontal ? line * width + i : i * width + line }
                for i in 0..<length where source[at(i)].isFinite {
                    var sum = 0.0
                    var count = 0
                    for j in max(0, i - radius)...min(length - 1, i + radius) {
                        let value = source[at(j)]
                        if value.isFinite {
                            sum += value
                            count += 1
                        }
                    }
                    output[at(i)] = sum / Double(count)
                }
            }
            return output
        }
        return pass(pass(heights, horizontal: true), horizontal: false)
    }
}
