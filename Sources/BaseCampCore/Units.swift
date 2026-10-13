import Foundation

/// How distances, speeds and heights are shown.
public enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    /// Metres and kilometres, km/h.
    case metric
    /// Miles and feet, mph.
    case statute
    /// Nautical miles and feet, knots.
    case nautical

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .metric: "Metric (km, m, km/h)"
        case .statute: "Statute (mi, ft, mph)"
        case .nautical: "Nautical (nm, ft, kn)"
        }
    }
}

/// How positions are written.
public enum CoordinateSystem: String, CaseIterable, Identifiable, Sendable {
    case decimalDegrees
    case degreesMinutes
    case degreesMinutesSeconds
    case utm

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .decimalDegrees: "Decimal degrees"
        case .degreesMinutes: "Degrees and decimal minutes"
        case .degreesMinutesSeconds: "Degrees, minutes, seconds"
        case .utm: "UTM"
        }
    }
}

/// Text for distances, speeds, heights and positions in the chosen units.
public enum UnitFormat {
    public static func distance(_ meters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .metric:
            return meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.2f km", meters / 1000)
        case .statute:
            let miles = meters / 1609.344
            return miles < 0.1 ? String(format: "%.0f ft", meters * 3.28084) : String(format: "%.2f mi", miles)
        case .nautical:
            return String(format: "%.2f nm", meters / 1852)
        }
    }

    public static func speed(_ metersPerSecond: Double, _ system: UnitSystem) -> String {
        switch system {
        case .metric: String(format: "%.1f km/h", metersPerSecond * 3.6)
        case .statute: String(format: "%.1f mph", metersPerSecond * 2.236936)
        case .nautical: String(format: "%.1f kn", metersPerSecond * 1.943844)
        }
    }

    public static func elevation(_ meters: Double, _ system: UnitSystem) -> String {
        switch system {
        case .metric: "\(Int(meters.rounded())) m"
        case .statute, .nautical: "\(Int((meters * 3.28084).rounded())) ft"
        }
    }

    /// The distance in the chosen unit, as a number, for charts. Metric is kilometres.
    public static func distanceValue(_ meters: Double, _ system: UnitSystem) -> Double {
        switch system {
        case .metric: meters / 1000
        case .statute: meters / 1609.344
        case .nautical: meters / 1852
        }
    }

    public static func distanceUnitName(_ system: UnitSystem) -> String {
        switch system {
        case .metric: "km"
        case .statute: "mi"
        case .nautical: "nm"
        }
    }

    public static func elevationValue(_ meters: Double, _ system: UnitSystem) -> Double {
        switch system {
        case .metric: meters
        case .statute, .nautical: meters * 3.28084
        }
    }

    public static func elevationUnitName(_ system: UnitSystem) -> String {
        switch system {
        case .metric: "m"
        case .statute, .nautical: "ft"
        }
    }

    /// A position in the chosen notation.
    public static func coordinate(_ coordinate: Coordinate, _ system: CoordinateSystem) -> String {
        switch system {
        case .decimalDegrees:
            return String(format: "%.6f°, %.6f°", coordinate.latitude, coordinate.longitude)
        case .degreesMinutes:
            return "\(hemisphere(coordinate.latitude, positive: "N", negative: "S")) "
                + degreesMinutes(abs(coordinate.latitude)) + "  "
                + "\(hemisphere(coordinate.longitude, positive: "E", negative: "W")) "
                + degreesMinutes(abs(coordinate.longitude))
        case .degreesMinutesSeconds:
            return degreesMinutesSeconds(coordinate.latitude, positive: "N", negative: "S") + "  "
                + degreesMinutesSeconds(coordinate.longitude, positive: "E", negative: "W")
        case .utm:
            guard let utm = UTM(coordinate) else { return "Outside UTM" }
            return "\(utm.zone)\(utm.band) \(utm.easting) E \(utm.northing) N"
        }
    }

    private static func hemisphere(_ value: Double, positive: String, negative: String) -> String {
        value < 0 ? negative : positive
    }

    /// 45° 07.4074′, rounded to four decimals of a minute, with the carry handled.
    private static func degreesMinutes(_ value: Double) -> String {
        let total = (value * 60 * 10_000).rounded()
        let degrees = Int(total / 600_000)
        let minutes = (total - Double(degrees) * 600_000) / 10_000
        return String(format: "%d° %07.4f′", degrees, minutes)
    }

    /// 45° 07′ 26.66″, rounded to hundredths of a second, with the carry handled.
    private static func degreesMinutesSeconds(_ value: Double, positive: String, negative: String) -> String {
        let total = (abs(value) * 3600 * 100).rounded()
        let degrees = Int(total / 360_000)
        let minutes = Int((total - Double(degrees) * 360_000) / 6000)
        let seconds = (total - Double(degrees) * 360_000 - Double(minutes) * 6000) / 100
        let hemi = value < 0 ? negative : positive
        return String(format: "%d° %02d′ %05.2f″ %@", degrees, minutes, seconds, hemi)
    }
}

/// A position in the Universal Transverse Mercator grid on the WGS 84 ellipsoid.
public struct UTM: Equatable, Sendable {
    public var zone: Int
    public var band: Character
    public var easting: Int
    public var northing: Int

    private static let bands = Array("CDEFGHJKLMNPQRSTUVWX")

    /// Nil outside the UTM latitudes (80° S to 84° N).
    public init?(_ coordinate: Coordinate) {
        let lat = coordinate.latitude
        guard lat >= -80, lat <= 84 else { return nil }
        let zone = min(60, max(1, Int((coordinate.longitude + 180) / 6) + 1))
        let bandIndex = min(Self.bands.count - 1, Int((lat + 80) / 8))
        let a = 6_378_137.0
        let f = 1 / 298.257223563
        let k0 = 0.9996
        let e2 = f * (2 - f)
        let ep2 = e2 / (1 - e2)

        let phi = lat * .pi / 180
        let lambda0 = Double((zone - 1) * 6 - 180 + 3) * .pi / 180
        let lambda = coordinate.longitude * .pi / 180

        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let t = tan(phi) * tan(phi)
        let c = ep2 * cos(phi) * cos(phi)
        let aa = (lambda - lambda0) * cos(phi)

        let m = a * ((1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * phi
            - (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) * sin(2 * phi)
            + (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * sin(4 * phi)
            - (35 * e2 * e2 * e2 / 3072) * sin(6 * phi))

        var easting = k0 * n * (aa + (1 - t + c) * pow(aa, 3) / 6
            + (5 - 18 * t + t * t + 72 * c - 58 * ep2) * pow(aa, 5) / 120) + 500_000
        var northing = k0 * (m + n * tan(phi) * (aa * aa / 2
            + (5 - t + 9 * c + 4 * c * c) * pow(aa, 4) / 24
            + (61 - 58 * t + t * t + 600 * c - 330 * ep2) * pow(aa, 6) / 720))
        if lat < 0 {
            northing += 10_000_000
        }
        easting = easting.rounded()
        northing = northing.rounded()

        self.zone = zone
        self.band = Self.bands[bandIndex]
        self.easting = Int(easting)
        self.northing = Int(northing)
    }
}
