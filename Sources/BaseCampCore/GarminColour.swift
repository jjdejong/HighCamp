import Foundation

/// BaseCamp's colour names for tracks and routes, as GPX writes them in `gpxx:DisplayColor`. The names are a fixed
/// palette of 16, plus Transparent, which means no colour. A name reads as its exact colour; a colour is written as
/// the nearest name, so a colour that came from a name gives back that name.
///
/// The RGB values are the usual web values for these names. BaseCamp's own values are not published; check them in
/// BaseCamp before relying on a particular shade.
enum GarminColour {
    private static let palette: [(name: String, hex: UInt32)] = [
        ("Black", 0x000000), ("DarkRed", 0x8B0000), ("DarkGreen", 0x006400), ("DarkYellow", 0x808000),
        ("DarkBlue", 0x00008B), ("DarkMagenta", 0x8B008B), ("DarkCyan", 0x008B8B), ("LightGray", 0xD3D3D3),
        ("DarkGray", 0xA9A9A9), ("Red", 0xFF0000), ("Green", 0x00FF00), ("Yellow", 0xFFFF00),
        ("Blue", 0x0000FF), ("Magenta", 0xFF00FF), ("Cyan", 0x00FFFF), ("White", 0xFFFFFF),
    ]

    /// The colour a name stands for. Nil for Transparent and for a name that is not in the palette.
    static func color(named name: String) -> ItemColor? {
        palette.first { $0.name == name }.map { ItemColor(hex: $0.hex) }
    }

    /// The palette name nearest to a colour, by distance in red, green and blue.
    static func name(nearest color: ItemColor) -> String {
        func distance(_ hex: UInt32) -> Double {
            let other = ItemColor(hex: hex)
            let dr = other.red - color.red, dg = other.green - color.green, db = other.blue - color.blue
            return dr * dr + dg * dg + db * db
        }
        // The palette is not empty, so there is always a nearest name.
        return palette.min { distance($0.hex) < distance($1.hex) }?.name ?? "Black"
    }
}

private extension ItemColor {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
