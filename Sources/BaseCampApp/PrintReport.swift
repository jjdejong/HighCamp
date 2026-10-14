import AppKit
import BaseCampCore
import BaseCampIMG
import Charts
import MapKit
import SwiftUI

/// The page printed for a track or route: its name, map, statistics and elevation profile.
struct ReportView: View {
    /// The width of the report, in points: a page of the report is this wide before it is fitted to the paper.
    static let width: CGFloat = 612
    /// The width of the map on the page, in points. The picture is 1080 by 800 pixels, so its height is 400.
    static let mapWidth: CGFloat = 540

    let title: String
    let stats: [(name: String, value: String)]
    let profile: [ElevationProfilePoint]
    let units: UnitSystem
    let map: NSImage?
    let scaleBar: ScaleBarMark?
    /// Whether the elevation profile is on this page. When it is not, it is on the next one (see `ProfilePageView`).
    let showsProfile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
            if let map {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: map)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Self.mapWidth, height: 400)
                    if let scaleBar {
                        ScaleBarView(mark: scaleBar)
                    }
                }
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
            if showsProfile {
                ProfileChart(profile: profile, units: units, height: 170)
            }
        }
        .padding(36)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

/// The elevation profile of a track or route: distance along the item against height.
struct ProfileChart: View {
    let profile: [ElevationProfilePoint]
    let units: UnitSystem
    /// The chart's height in points. On the first page it is 170; alone on the second page it is taller.
    let height: CGFloat

    var body: some View {
        if profile.count > 1 {
            Chart(profile) { point in
                AreaMark(
                    x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                    yStart: .value("Base", UnitFormat.elevationValue(profile.map(\.value).min() ?? 0, units)),
                    yEnd: .value("Elevation", UnitFormat.elevationValue(point.value, units))
                )
                .foregroundStyle(Color.orange.opacity(0.25))
                LineMark(
                    x: .value("Distance", UnitFormat.distanceValue(point.distanceMeters, units)),
                    y: .value("Elevation", UnitFormat.elevationValue(point.value, units))
                )
                .foregroundStyle(.orange)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxisLabel(UnitFormat.distanceUnitName(units))
            .chartYAxisLabel(UnitFormat.elevationUnitName(units))
            .frame(height: height)
        }
    }
}

/// The second page of a report, when the elevation profile does not fit on the first: the item's name and its profile.
struct ProfilePageView: View {
    let title: String
    let profile: [ElevationProfilePoint]
    let units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(title): elevation profile")
                .font(.system(size: 18, weight: .semibold))
            ProfileChart(profile: profile, units: units, height: 400)
        }
        .padding(36)
        .frame(width: ReportView.width, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

/// The report's pages, and the page height they are cut to, in report points.
struct ReportPages {
    let images: [NSImage]
    let pageHeight: CGFloat
}

/// Draws the pages of a report one under the other, each page in its own rectangle, so printing cuts between them.
private final class ReportPagesView: NSView {
    private let pages: [NSImage]
    private let pageHeight: CGFloat

    init(pages: [NSImage], pageHeight: CGFloat, width: CGFloat) {
        self.pages = pages
        self.pageHeight = pageHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: pageHeight * CGFloat(pages.count)))
    }

    required init?(coder: NSCoder) {
        fatalError("ReportPagesView is not made from a nib")
    }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageHeight, width: bounds.width, height: pageHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        for (index, page) in pages.enumerated() {
            let top = CGFloat(index) * pageHeight
            page.draw(in: NSRect(x: 0, y: top, width: bounds.width, height: page.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The scale bar under the map: its length as a label, and the bar's width on the page.
struct ScaleBarMark {
    let label: String
    let width: CGFloat
}

/// A scale bar: the label above a line with a tick at each end.
private struct ScaleBarView: View {
    let mark: ScaleBarMark

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(mark.label)
                .font(.system(size: 11))
            ZStack(alignment: .leading) {
                Rectangle()
                    .frame(width: mark.width, height: 3)
                HStack {
                    Rectangle().frame(width: 2, height: 9)
                    Spacer(minLength: 0)
                    Rectangle().frame(width: 2, height: 9)
                }
                .frame(width: mark.width)
            }
            .frame(width: mark.width, height: 9, alignment: .leading)
        }
    }
}

/// Builds the report for the selected track or route and sends it to the print dialog.
@MainActor
enum ReportPrinter {
    /// The map picture's size in pixels.
    private static let pictureSize = CGSize(width: 1080, height: 800)

    static func printSelection(store: LibraryStore, display: DisplaySettings, base: PictureBase) async {
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

        let bounds = reportBounds(for: coordinates)
        let pins = bounds.map { area in waypointPins(in: area, waypoints: store.library.waypoints) } ?? []
        let rendered = await mapImage(for: coordinates, bounds: bounds, pins: pins, base: base)
        if let message = rendered?.missingTilesMessage {
            store.errorMessage = message
        }
        let rows = statisticRows(stats, units: display.units, coordinates: display.coordinates, start: coordinates.first)
        let scale = bounds.flatMap { scaleBar(for: $0, units: display.units) }
        guard let pages = layOut(title: title, stats: rows, profile: profile, units: display.units, map: rendered?.image, scaleBar: scale) else {
            store.errorMessage = "The report could not be drawn."
            return
        }
        #if DEBUG
        // `--report-png PATH` and `--report-pdf PATH` save the report instead of printing it, for testing.
        if let path = BaseCampApp.launchValue("--report-png") {
            writePNGs(pages.images, to: path)
            return
        }
        if let path = BaseCampApp.launchValue("--report-pdf") {
            savePDF(pages, to: URL(fileURLWithPath: path))
            return
        }
        #endif
        let operation = NSPrintOperation(view: pagesView(pages), printInfo: printInfo())
        operation.showsPrintPanel = true
        operation.run()
    }

    /// The print settings the report is laid out for: the default paper, the report fitted to its width, and pages cut
    /// between the rectangles of `ReportPagesView`.
    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        return info
    }

    private static func pagesView(_ pages: ReportPages) -> NSView {
        ReportPagesView(pages: pages.images, pageHeight: pages.pageHeight, width: ReportView.width)
    }

    /// The report as pages. One page when the whole report fits on the paper; otherwise the report without its
    /// profile, then the profile on a second page (see `ReportLayout`).
    @MainActor
    private static func layOut(
        title: String,
        stats: [(name: String, value: String)],
        profile: [ElevationProfilePoint],
        units: UnitSystem,
        map: NSImage?,
        scaleBar: ScaleBarMark?
    ) -> ReportPages? {
        let printable = printInfo().imageablePageBounds
        let pageHeight = printable.width > 0 && printable.height > 0
            ? ReportLayout.pageHeight(printableWidth: printable.width, printableHeight: printable.height, reportWidth: ReportView.width)
            : CGFloat.greatestFiniteMagnitude
        let report = { (showsProfile: Bool) in
            ReportView(title: title, stats: stats, profile: profile, units: units, map: map, scaleBar: scaleBar, showsProfile: showsProfile)
        }
        guard let whole = render(report(true)) else { return nil }
        guard ReportLayout.profileOnSecondPage(reportHeight: whole.size.height, pageHeight: pageHeight) else {
            return ReportPages(images: [whole], pageHeight: pageHeight)
        }
        guard let first = render(report(false)),
              let second = render(ProfilePageView(title: title, profile: profile, units: units)) else { return nil }
        return ReportPages(images: [first, second], pageHeight: pageHeight)
    }

    /// One view as an image, at twice the point size.
    @MainActor
    private static func render<Content: View>(_ view: Content) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    #if DEBUG
    /// Writes each page as a PNG: the path itself for one page, or the path with -1, -2 and so on before its extension.
    private static func writePNGs(_ pages: [NSImage], to path: String) {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().path
        for (index, page) in pages.enumerated() {
            let target = pages.count == 1 ? url : URL(fileURLWithPath: "\(stem)-\(index + 1).\(url.pathExtension)")
            if let tiff = page.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: target)
            }
        }
    }

    /// Saves the report as a PDF, without the print dialog.
    @MainActor
    private static func savePDF(_ pages: ReportPages, to url: URL) {
        let info = printInfo()
        info.jobDisposition = .save
        let settings = info.dictionary()
        settings.setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSString)
        let operation = NSPrintOperation(view: pagesView(pages), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }
    #endif

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

    /// The area the report's map shows: the item's extent with a margin.
    private static func reportBounds(for coordinates: [Coordinate]) -> GeoBounds? {
        guard let first = coordinates.first else { return nil }
        var north = first.latitude, south = first.latitude, east = first.longitude, west = first.longitude
        for coordinate in coordinates {
            north = max(north, coordinate.latitude)
            south = min(south, coordinate.latitude)
            east = max(east, coordinate.longitude)
            west = min(west, coordinate.longitude)
        }
        let padding = max(north - south, east - west) * 0.08 + 0.001
        return GeoBounds(north: north + padding, east: east + padding, south: south - padding, west: west - padding)
    }

    /// The scale bar for the map of `bounds`. About a fifth of the map's width, rounded to 1, 2 or 5 in the chosen
    /// units. The picture is widened where needed to keep its shape, so the width comes from the same projection.
    /// The bar is exact along the middle latitude; the scale changes a little from top to bottom of a large map.
    static func scaleBar(for bounds: GeoBounds, units: UnitSystem) -> ScaleBarMark? {
        let projection = PictureProjection(
            north: bounds.north, east: bounds.east, south: bounds.south, west: bounds.west,
            width: pictureSize.width, height: pictureSize.height
        )
        let middle = (projection.north + projection.south) / 2
        let metresAcross = Geodesy.distance(
            from: Coordinate(latitude: middle, longitude: projection.west),
            to: Coordinate(latitude: middle, longitude: projection.east)
        )
        let unitMetres: Double = switch units {
        case .metric: 1
        case .statute: 1609.344
        case .nautical: 1852
        }
        guard let value = ScaleBar.roundLength(metresAcross / unitMetres, fraction: 0.2) else { return nil }
        let length = value * unitMetres
        return ScaleBarMark(
            label: UnitFormat.distance(length, units),
            width: CGFloat(length / metresAcross) * ReportView.mapWidth
        )
    }

    /// The library's waypoints that lie in the report's map area, drawn with their symbols.
    private static func waypointPins(in area: GeoBounds, waypoints: [Waypoint]) -> [MapPin] {
        waypoints.filter { waypoint in
            let point = waypoint.coordinate
            return point.latitude <= area.north && point.latitude >= area.south
                && point.longitude <= area.east && point.longitude >= area.west
        }.map { waypoint in
            MapPin(id: "waypoint-\(waypoint.id)", coordinate: waypoint.coordinate, style: .waypoint(selected: false, symbol: waypoint.symbol), item: nil, title: waypoint.name)
        }
    }

    /// The base map of the item's area, with the item drawn on it and the waypoints in the area.
    private static func mapImage(for coordinates: [Coordinate], bounds: GeoBounds?, pins: [MapPin], base: PictureBase) async -> RenderedMap? {
        guard let bounds else { return nil }
        let line = MapLine(id: "report", coordinates: coordinates, color: .red, rgb: nil, width: 4)
        let scene = MapScene(layers: [.library: MapLayerContent(pins: pins, lines: [line])])
        return try? await MapImageExport.render(scene: scene, bounds: bounds, size: pictureSize, base: base)
    }
}
