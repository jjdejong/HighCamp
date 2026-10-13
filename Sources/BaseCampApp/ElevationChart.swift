import BaseCampCore
import Charts
import SwiftUI

extension ProfileSeries {
    /// The name of the series in the chart's picker.
    var title: String {
        switch self {
        case .elevation: "Elevation"
        case .heartRate: "Heart rate"
        case .cadence: "Cadence"
        case .power: "Power"
        case .temperature: "Temperature"
        }
    }

    /// The colour of the series' line.
    var colour: Color {
        switch self {
        case .elevation: .orange
        case .heartRate: .red
        case .cadence: .green
        case .power: .purple
        case .temperature: .teal
        }
    }

    /// The unit the series is shown in, for the chart's axis. Heights follow the chosen units.
    func unitName(_ units: UnitSystem) -> String {
        switch self {
        case .elevation: UnitFormat.elevationUnitName(units)
        case .heartRate: "bpm"
        case .cadence: "rpm"
        case .power: "W"
        case .temperature: "°C"
        }
    }

    /// The value shown on the axis: a height in the chosen units, or the reading as it is.
    func axisValue(_ value: Double, _ units: UnitSystem) -> Double {
        self == .elevation ? UnitFormat.elevationValue(value, units) : value
    }
}

/// One series against distance, in the chosen units. Moving the pointer over the chart marks that place on the map.
struct ElevationChart: View {
    let profile: [ElevationProfilePoint]
    let series: ProfileSeries
    @Environment(LibraryStore.self) private var store
    @Environment(DisplaySettings.self) private var display
    /// The distance under the pointer, in the chosen distance unit.
    @State private var selectedDistance: Double?

    var body: some View {
        let units = display.units
        // The area fills down to the lowest point, not to zero, so the shape of the line stays visible.
        let lowest = profile.map { series.axisValue($0.value, units) }.min() ?? 0
        Chart(profile) { point in
            AreaMark(
                x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                yStart: .value("Base", lowest),
                yEnd: .value(series.title, series.axisValue(point.value, units))
            )
            .foregroundStyle(series.colour.opacity(0.2))

            LineMark(
                x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                y: .value(series.title, series.axisValue(point.value, units))
            )
            .foregroundStyle(series.colour)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel(UnitFormat.distanceUnitName(units))
        .chartYAxisLabel(series.unitName(units))
        .chartXSelection(value: $selectedDistance)
        .frame(height: 140)
        .onChange(of: selectedDistance) { _, distance in
            store.profileCoordinate = distance.flatMap { nearest(to: $0, units: units)?.coordinate }
        }
        .onDisappear {
            store.profileCoordinate = nil
        }
    }

    /// The profile point whose distance is closest to `distance` (in the chosen unit).
    private func nearest(to distance: Double, units: UnitSystem) -> ElevationProfilePoint? {
        profile.min { a, b in
            abs(UnitFormat.distanceValue(a.distanceMeters, units) - distance)
                < abs(UnitFormat.distanceValue(b.distanceMeters, units) - distance)
        }
    }
}
