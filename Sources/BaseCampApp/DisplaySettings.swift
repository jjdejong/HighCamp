import BaseCampCore
import Foundation
import Observation

/// How distances, speeds, heights and positions are shown. Kept between launches.
@MainActor
@Observable
final class DisplaySettings {
    var units: UnitSystem {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "display.units") }
    }
    var coordinates: CoordinateSystem {
        didSet { UserDefaults.standard.set(coordinates.rawValue, forKey: "display.coordinates") }
    }

    init() {
        let defaults = UserDefaults.standard
        units = UnitSystem(rawValue: defaults.string(forKey: "display.units") ?? "") ?? .metric
        coordinates = CoordinateSystem(rawValue: defaults.string(forKey: "display.coordinates") ?? "") ?? .decimalDegrees
    }
}
