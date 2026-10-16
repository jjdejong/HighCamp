import Foundation

/// The colour steep stretches are drawn in over a line: orange, or another bright colour when the line itself is
/// near orange (tracks are orange by default) or near that one too.
public enum SteepHighlight {
    public static let orange = ItemColor(red: 1.0, green: 0.55, blue: 0.0)
    public static let red = ItemColor(red: 0.86, green: 0.08, blue: 0.12)
    public static let yellow = ItemColor(red: 0.98, green: 0.80, blue: 0.0)

    /// Hues closer than this, in degrees, are taken for the same colour.
    static let distinctHues = 35.0

    public static func colour(against line: ItemColor) -> ItemColor {
        guard let lineHue = hue(of: line) else { return orange }
        return [orange, red, yellow].first { candidate in
            guard let hue = hue(of: candidate) else { return false }
            let apart = abs(hue - lineHue).truncatingRemainder(dividingBy: 360)
            return min(apart, 360 - apart) >= distinctHues
        } ?? orange
    }

    /// The hue in degrees, or nil for a grey, which any colour stands out from.
    static func hue(of colour: ItemColor) -> Double? {
        let high = max(colour.red, colour.green, colour.blue)
        let low = min(colour.red, colour.green, colour.blue)
        let chroma = high - low
        guard high > 0, chroma / high > 0.3 else { return nil }
        let sector: Double
        if high == colour.red {
            sector = ((colour.green - colour.blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if high == colour.green {
            sector = (colour.blue - colour.red) / chroma + 2
        } else {
            sector = (colour.red - colour.green) / chroma + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
}
