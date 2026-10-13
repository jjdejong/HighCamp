import AppKit
import BaseCampCore
import BaseCampIMG
import Charts
import MapKit
import SwiftUI

/// The page printed for a track or route: its name, map, statistics and elevation profile.
struct ReportView: View {
    let title: String
    let stats: [(name: String, value: String)]
    let profile: [ElevationProfilePoint]
    let units: UnitSystem
    let map: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
            if let map {
                Image(nsImage: map)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 540, height: 400)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(stats.indices, id: \.self) { index in
                    GridRow {
                        Text(stats[index].name)
                            .foregroundStyle(.secondary)
                        Text(stats[index].value)
                            .monospacedDigit()
                    }
                }
            }
            if profile.count > 1 {
                Chart(profile) { point in
                    AreaMark(
                        x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                        yStart: .value("Base", profile.map(\.elevation).min() ?? 0),
                        yEnd: .value("Elevation", UnitFormat.elevationValue(point.elevation, units))
                    )
                    .foregroundStyle(Color.orange.opacity(0.25))
                    LineMark(
                        x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                        y: .value("Elevation", UnitFormat.elevationValue(point.elevation, units))
                    )
                    .foregroundStyle(.orange)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel(UnitFormat.distanceUnitName(units))
                .chartYAxisLabel(UnitFormat.elevationUnitName(units))
                .frame(height: 170)
            }
        }
        .padding(36)
        .frame(width: 612, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

/// Builds the report for the selected track or route and sends it to the print dialog.
@MainActor
enum ReportPrinter {
    static func printSelection(store: LibraryStore, display: DisplaySettings, base: BaseMapLayer, contours: Bool) async {
        let title: String
        let coordinates: [Coordinate]
        let stats: ActivityStatistics
        let profile: [ElevationProfilePoint]
        switch store.selection {
        case .track(let id)?:
            guard let track = store.track(id) else { return }
            title = track.name
            coordinates = track.segments.flatMap { $0.map(\.coordinate) }
            stats = track.statistics
            profile = track.elevationProfile
        case .route(let id)?:
            guard let route = store.route(id) else { return }
            title = route.name
            coordinates = route.points.map(\.coordinate)
            stats = route.statistics
            profile = route.elevationProfile
        default:
            store.errorMessage = "Select a route or track to print a report."
            return
        }

        let map = await mapImage(for: coordinates, base: base, contours: contours)
        let report = ReportView(
            title: title,
            stats: statisticRows(stats, units: display.units, coordinates: display.coordinates, start: coordinates.first),
            profile: profile,
            units: display.units,
            map: map
        )
        let renderer = ImageRenderer(content: report)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            store.errorMessage = "The report could not be drawn."
            return
        }
        // `--report-png PATH` saves the report instead of printing it, for testing.
        if let path = BaseCampApp.launchValue("--report-png") {
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        let operation = NSPrintOperation(view: imageView, printInfo: info)
        operation.showsPrintPanel = true
        operation.run()
    }

    /// The statistics as name and value rows, in the chosen units.
    static func statisticRows(_ stats: ActivityStatistics, units: UnitSystem, coordinates: CoordinateSystem, start: Coordinate?) -> [(name: String, value: String)] {
        var rows: [(name: String, value: String)] = [("Distance", UnitFormat.distance(stats.distanceMeters, units))]
        if let total = stats.totalTime, let text = Format.seconds(total) {
            rows.append(("Total time", text))
        }
        if let moving = stats.movingTime, let text = Format.seconds(moving) {
            rows.append(("Moving time", text))
        }
        if let speed = stats.averageSpeed {
            rows.append(("Average speed", UnitFormat.speed(speed, units)))
        }
        if let speed = stats.maximumSpeed {
            rows.append(("Maximum speed", UnitFormat.speed(speed, units)))
        }
        if let ascent = stats.ascentMeters {
            rows.append(("Ascent", UnitFormat.elevation(ascent, units)))
        }
        if let descent = stats.descentMeters {
            rows.append(("Descent", UnitFormat.elevation(descent, units)))
        }
        if let lowest = stats.minimumElevation, let highest = stats.maximumElevation {
            rows.append(("Lowest / highest", "\(UnitFormat.elevation(lowest, units)) / \(UnitFormat.elevation(highest, units))"))
        }
        if let start {
            rows.append(("Start", UnitFormat.coordinate(start, coordinates)))
        }
        return rows
    }

    /// Apple's map of the item's area, with the item drawn on it.
    private static func mapImage(for coordinates: [Coordinate], base: BaseMapLayer, contours: Bool) async -> NSImage? {
        guard let first = coordinates.first else { return nil }
        var north = first.latitude, south = first.latitude, east = first.longitude, west = first.longitude
        for coordinate in coordinates {
            north = max(north, coordinate.latitude)
            south = min(south, coordinate.latitude)
            east = max(east, coordinate.longitude)
            west = min(west, coordinate.longitude)
        }
        let padding = max(north - south, east - west) * 0.08 + 0.001
        let bounds = GeoBounds(north: north + padding, east: east + padding, south: south - padding, west: west - padding)
        let scene = MapScene(lines: [MapLine(id: "report", coordinates: coordinates, color: .red, rgb: nil, width: 4)])
        return try? await MapImageExport.render(scene: scene, bounds: bounds, size: CGSize(width: 1080, height: 800), base: base, contours: contours)
    }
}
