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

/// One series against distance, in the chosen units. Moving the pointer over the chart moves the profile cursor,
/// which is drawn as a line here and as a marker on the map, and stays where it was left. With `pickable`, dragging
/// across the chart picks a stretch of the line, shaded here and on the map.
struct ElevationChart: View {
    let profile: [ElevationProfilePoint]
    let series: ProfileSeries
    let pickable: Bool
    /// The stretch shown, in metres. Nil shows the whole profile.
    var domain: ClosedRange<Double>?
    /// The chart's height; nil fills the space it is given.
    var height: CGFloat? = 140
    /// At most about this many points are drawn. Charts slows down with many thousand marks.
    var drawLimit = 500
    /// Stretches steeper than the grade limit, in metres, shaded in `steepColour`.
    var steep: [ClosedRange<Double>] = []
    var steepColour: Color = .orange
    @Environment(LibraryStore.self) private var store
    @Environment(DisplaySettings.self) private var display
    /// The distance under the pointer, in the chosen distance unit.
    @State private var selectedDistance: Double?

    var body: some View {
        let units = display.units
        let shown = visibleRange
        let points = visiblePoints(in: shown).thinnedForDrawing(limit: drawLimit)
        let values = points.map { series.axisValue($0.value, units) }
        // The area fills down to the lowest point, not to zero, so the shape of the line stays visible.
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        let pad = max((highest - lowest) * 0.05, 1)
        let xDomain = UnitFormat.distanceValue(shown.lowerBound, units)...UnitFormat.distanceValue(shown.upperBound, units)
        Chart {
            ForEach(Array(steep.enumerated()), id: \.offset) { _, stretch in
                if stretch.overlaps(shown) {
                    RectangleMark(
                        xStart: .value("From", UnitFormat.distanceValue(max(stretch.lowerBound, shown.lowerBound), units)),
                        xEnd: .value("To", UnitFormat.distanceValue(min(stretch.upperBound, shown.upperBound), units)),
                        yStart: .value("Base", lowest - pad),
                        yEnd: .value("Top", highest + pad)
                    )
                    .foregroundStyle(steepColour.opacity(0.22))
                }
            }
            if pickable, let picked = store.profileRange {
                RectangleMark(
                    xStart: .value("From", UnitFormat.distanceValue(max(picked.lowerBound, shown.lowerBound), units)),
                    xEnd: .value("To", UnitFormat.distanceValue(min(picked.upperBound, shown.upperBound), units)),
                    yStart: .value("Base", lowest - pad),
                    yEnd: .value("Top", highest + pad)
                )
                .foregroundStyle(Color.accentColor.opacity(0.2))
            }
            ForEach(points) { point in
                AreaMark(
                    x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                    yStart: .value("Base", lowest - pad),
                    yEnd: .value(series.title, series.axisValue(point.value, units))
                )
                .foregroundStyle(series.colour.opacity(0.2))

                LineMark(
                    x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                    y: .value(series.title, series.axisValue(point.value, units))
                )
                .foregroundStyle(series.colour)
            }
            if let cursor = store.profileCursor, shown.contains(cursor) {
                RuleMark(x: .value("Cursor", UnitFormat.distanceValue(cursor, units)))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let value = profile.value(at: cursor) {
                    PointMark(
                        x: .value("Cursor", UnitFormat.distanceValue(cursor, units)),
                        y: .value(series.title, series.axisValue(value, units))
                    )
                    .foregroundStyle(series.colour)
                    .symbolSize(40)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: (lowest - pad)...(highest + pad))
        .chartPlotStyle { $0.clipped() }
        .chartXAxisLabel(UnitFormat.distanceUnitName(units))
        .chartYAxisLabel(series.unitName(units))
        .chartXSelection(value: $selectedDistance)
        .chartXSelection(range: pickedRange(units))
        .frame(height: height)
        .onChange(of: selectedDistance) { _, distance in
            // Leaving the chart gives nil; the cursor stays where it was, so it can still be used.
            if let distance {
                store.profileCursor = UnitFormat.distanceMeters(fromValue: distance, units)
            }
        }
    }

    /// The stretch shown, in metres.
    private var visibleRange: ClosedRange<Double> {
        let full = (profile.first?.distanceMeters ?? 0)...max(profile.last?.distanceMeters ?? 0, (profile.first?.distanceMeters ?? 0) + 1)
        return domain.map { $0.clamped(to: full) } ?? full
    }

    /// The points in the stretch shown, with one more on each side so the line runs to the chart's edges.
    private func visiblePoints(in range: ClosedRange<Double>) -> [ElevationProfilePoint] {
        guard domain != nil else { return profile }
        guard let first = profile.firstIndex(where: { $0.distanceMeters >= range.lowerBound }) else { return Array(profile.suffix(1)) }
        let last = profile.lastIndex(where: { $0.distanceMeters <= range.upperBound }) ?? first
        return Array(profile[max(first - 1, 0)...min(max(last, first) + 1, profile.count - 1)])
    }

    /// The stretch picked on the profile, in the chosen distance unit, when the chart can pick one.
    private func pickedRange(_ units: UnitSystem) -> Binding<ClosedRange<Double>?> {
        Binding(
            get: {
                guard pickable, let picked = store.profileRange else { return nil }
                return UnitFormat.distanceValue(picked.lowerBound, units)...UnitFormat.distanceValue(picked.upperBound, units)
            },
            set: { picked in
                // Charts sets nil when the mouse is released, which would drop the stretch before it can be deleted.
                // So nil is ignored; the stretch is cleared by Clear, by deleting it, or by selecting another item.
                guard pickable, let picked else { return }
                store.profileRange = UnitFormat.distanceMeters(fromValue: picked.lowerBound, units)...UnitFormat.distanceMeters(fromValue: picked.upperBound, units)
            }
        )
    }
}
