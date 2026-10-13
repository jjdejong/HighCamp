import BaseCampCore
import Charts
import SwiftUI

/// Elevation against distance, in the chosen units. Moving the pointer over the chart marks that place on the map.
struct ElevationChart: View {
    let profile: [ElevationProfilePoint]
    @Environment(LibraryStore.self) private var store
    @Environment(DisplaySettings.self) private var display
    /// The distance under the pointer, in the chosen distance unit.
    @State private var selectedDistance: Double?

    var body: some View {
        let units = display.units
        // The area fills down to the lowest point, not to zero, so the shape of the climb stays visible.
        let lowest = profile.map { UnitFormat.elevationValue($0.value, units) }.min() ?? 0
        Chart(profile) { point in
            AreaMark(
                x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                yStart: .value("Base", lowest),
                yEnd: .value("Elevation", UnitFormat.elevationValue(point.value, units))
            )
            .foregroundStyle(Color.orange.opacity(0.2))

            LineMark(
                x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                y: .value("Elevation", UnitFormat.elevationValue(point.value, units))
            )
            .foregroundStyle(.orange)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel(UnitFormat.distanceUnitName(units))
        .chartYAxisLabel(UnitFormat.elevationUnitName(units))
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
