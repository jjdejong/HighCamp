import AppKit
import BaseCampCore
import SwiftUI

/// The profile of the selected track or route, under the map, as large as the user drags it. It shares the cursor
/// and the picked stretch with the inspector's small profile and with the map. Over the chart, scrolling up or down
/// zooms around the cursor and scrolling sideways pans; dragging picks a stretch.
struct ProfilePane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DisplaySettings.self) private var display
    @Environment(TrackDEMStore.self) private var trackDEMs
    @Environment(ElevationSettings.self) private var elevation
    @State private var series = ProfileSeries.elevation
    /// Heights read every few metres from the item's track DEM, when it has one.
    @State private var demProfile: [ElevationProfilePoint]?
    /// Show the heights from the track DEM rather than the line's own points, when there is a track DEM.
    @AppStorage("display.profileFromDEM") private var fromDEM = true
    /// The stretch shown, in metres. Nil shows the whole profile.
    @State private var domain: ClosedRange<Double>?
    @State private var isHovering = false
    @State private var chartWidth: CGFloat = 1
    @State private var scrollMonitor: Any?

    /// Shorter than this, in metres, the chart does not zoom further.
    private static let shortestDomain = 20.0

    private struct Item {
        let name: String
        let isTrack: Bool
        let statistics: ActivityStatistics
        let profile: (ProfileSeries) -> [ElevationProfilePoint]
    }

    private var item: Item? {
        switch store.selection {
        case .track(let id)?:
            guard let track = store.track(id) else { return nil }
            return Item(name: track.name, isTrack: true, statistics: track.statistics, profile: { track.profile(of: $0) })
        case .route(let id)?:
            guard let route = store.route(id) else { return nil }
            return Item(name: route.name, isTrack: false, statistics: route.statistics, profile: { route.profile(of: $0) })
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                let choices = item.statistics.availableSeries
                let shown = choices.contains(series) ? series : (choices.first ?? .elevation)
                let dem = fromDEM ? demProfile.flatMap { $0.count > 1 ? $0 : nil } : nil
                let ownHeights = item.profile(.elevation)
                let heights = dem ?? ownHeights
                let points = shown == .elevation ? heights : item.profile(shown)
                header(item, choices: choices, shown: shown, heights: heights, length: points.last?.distanceMeters ?? 0)
                Divider()
                if points.count > 1 {
                    ElevationChart(profile: points, series: shown, pickable: item.isTrack, domain: domain, height: nil, drawLimit: 2_000)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { chartWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, width in chartWidth = width }
                        })
                        .onHover { isHovering = $0 }
                } else {
                    placeholder("This item has no heights. Use Elevations from Model in the inspector.")
                }
            } else {
                placeholder("Select a track or route to see its profile.")
            }
        }
        .background(.background)
        .onChange(of: store.selection) { _, _ in
            domain = nil
        }
        .task(id: DEMRequest(item: store.selection, library: store.revision, dem: trackDEMs.revision)) {
            demProfile = nil
            guard let item = store.selection else { return }
            demProfile = await trackDEMs.profile(for: item, store: store)
        }
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private func header(_ item: Item, choices: [ProfileSeries], shown: ProfileSeries, heights: [ElevationProfilePoint], length: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                if choices.count > 1 {
                    Picker("Show", selection: $series) {
                        ForEach(choices, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                demControls
                Spacer(minLength: 8)
                buttons(item, length: length)
            }
            readout(series: shown, profile: shown == .elevation ? heights : item.profile(shown), heights: heights)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Where the heights come from: the line's own points, or its track DEM, read every few metres. Without a
    /// track DEM, a button builds one; while it is built, what is happening.
    @ViewBuilder
    private var demControls: some View {
        if let status = trackDEMs.status {
            ProgressView().controlSize(.mini)
            Text(status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let selection = store.selection, let info = trackDEMs.info(for: selection, store: store) {
            Picker("Heights", selection: $fromDEM) {
                Text("Points").tag(false)
                Text("DEM \(Self.resolutionText(info.resolution))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Heights at the line's own points, or read from its track DEM every few metres (\(info.tiles) tiles within \(Int(info.corridor)) m)")
        } else if let selection = store.selection {
            Button("Build Track DEM") {
                Task { await trackDEMs.build(selection, store: store, tileFolder: elevation.tileFolder, corridor: elevation.corridor) }
            }
            .help("Gather the high-resolution tiles along this line from \(elevation.tileFolder.lastPathComponent) into a DEM of its own, for an exact profile")
        }
    }

    private static func resolutionText(_ metres: Double) -> String {
        metres < 10 ? String(format: "%g m", (metres * 10).rounded() / 10) : "\(Int(metres.rounded())) m"
    }

    private func buttons(_ item: Item, length: Double) -> some View {
        HStack(spacing: 8) {
            zoomButtons(length: length)
            if item.isTrack {
                Divider().frame(height: 16)
                Button("Delete Selected Points") { store.deleteProfileRange() }
                    .disabled(store.profileRange == nil)
                    .help("Drag across the profile to pick points, then delete them")
                Button("Clear") { store.profileRange = nil }
                    .disabled(store.profileRange == nil)
                    .help("Forget the stretch picked on the profile")
                Button("Split Here") { store.splitSelectedTrackAtCursor() }
                    .disabled(store.profileCursor == nil)
                    .help("Cut the track in two at the profile cursor")
            }
            Button {
                display.showsProfilePane = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide the profile (⌥⌘P)")
        }
        .fixedSize()
    }

    private struct DEMRequest: Equatable {
        let item: LibraryItem?
        let library: Int
        let dem: Int
    }

    /// The values at the cursor on one line, and the size and averages of the picked stretch on the next.
    private func readout(series: ProfileSeries, profile: [ElevationProfilePoint], heights: [ElevationProfilePoint]) -> some View {
        let units = display.units
        var parts: [String] = []
        var picked: String?
        if let cursor = store.profileCursor {
            parts.append("At \(UnitFormat.distance(cursor, units))")
            if let height = heights.value(at: cursor) {
                parts.append(UnitFormat.elevation(height, units))
            }
            if let grade = heights.grade(at: cursor, window: 50) {
                parts.append(String(format: "grade %+.1f %%", grade))
            }
            if series != .elevation, let value = profile.value(at: cursor) {
                parts.append("\(Int(value.rounded())) \(series.unitName(units))")
            }
        }
        if let range = store.profileRange {
            var line = "Picked \(UnitFormat.distance(range.upperBound - range.lowerBound, units))"
            let inside = heights.filter { range.contains($0.distanceMeters) }.map(\.value)
            if let climb = ActivityStatistics.climb(inside, threshold: ActivityStatistics.elevationNoise) {
                line += ", ↑ \(UnitFormat.elevation(climb.ascent, units)) ↓ \(UnitFormat.elevation(climb.descent, units))"
            }
            if let grade = heights.averageGrade(over: range) {
                line += String(format: ", avg grade %+.1f %%", grade)
            }
            if series == .elevation {
                if let height = heights.average(over: range) {
                    line += ", avg \(UnitFormat.elevation(height, units))"
                }
            } else if let value = profile.average(over: range) {
                line += ", avg \(Int(value.rounded())) \(series.unitName(units))"
            }
            picked = line
        }
        // Both lines are kept when empty, so the chart does not jump when the cursor or a stretch first appears.
        return VStack(alignment: .leading, spacing: 2) {
            Text(parts.isEmpty ? "Move the pointer over the profile or the line on the map" : parts.joined(separator: "   "))
            Text(picked ?? "Drag across the profile to pick a stretch")
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .font(.callout)
    }

    private func zoomButtons(length: Double) -> some View {
        HStack(spacing: 4) {
            Button { zoom(by: 0.5, length: length) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in around the cursor (or scroll up over the profile)")
            Button { zoom(by: 2, length: length) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(domain == nil)
                .help("Zoom out (or scroll down over the profile)")
            Button("Zoom to Picked") {
                if let range = store.profileRange {
                    let margin = (range.upperBound - range.lowerBound) * 0.05
                    setDomain((range.lowerBound - margin)...(range.upperBound + margin), length: length)
                }
            }
            .disabled(store.profileRange == nil)
            Button("Show All") { domain = nil }
                .disabled(domain == nil)
        }
    }

    // MARK: Zoom and pan

    /// The profile's full length, in metres, for the selected item as shown.
    private var currentLength: Double {
        guard let item else { return 0 }
        let choices = item.statistics.availableSeries
        let shown = choices.contains(series) ? series : (choices.first ?? .elevation)
        return item.profile(shown).last?.distanceMeters ?? 0
    }

    /// Scales the stretch shown by `factor` around the cursor, or around its middle when the cursor is outside it.
    private func zoom(by factor: Double, length: Double) {
        guard length > 0 else { return }
        let current = domain ?? 0...length
        let span = current.upperBound - current.lowerBound
        let anchor = store.profileCursor.flatMap { current.contains($0) ? $0 : nil } ?? (current.lowerBound + span / 2)
        let newSpan = min(max(span * factor, Self.shortestDomain), length)
        let lower = anchor - (anchor - current.lowerBound) * newSpan / span
        setDomain(lower...(lower + newSpan), length: length)
    }

    /// Moves the stretch shown by `metres`.
    private func pan(by metres: Double, length: Double) {
        guard let current = domain else { return }
        setDomain((current.lowerBound + metres)...(current.upperBound + metres), length: length)
    }

    /// Shows `range`, kept inside the profile; the whole profile when it covers it.
    private func setDomain(_ range: ClosedRange<Double>, length: Double) {
        let span = range.upperBound - range.lowerBound
        guard span < length else {
            domain = nil
            return
        }
        let lower = min(max(range.lowerBound, 0), length - span)
        domain = lower...(lower + span)
    }

    /// Scrolling over the chart zooms and pans it instead of scrolling the window.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            let length = currentLength
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let dx = event.scrollingDeltaX * scale
            let dy = event.scrollingDeltaY * scale
            if abs(dy) >= abs(dx), dy != 0 {
                zoom(by: exp(-Double(dy) / 60), length: length)
            } else if dx != 0, let current = domain {
                let span = current.upperBound - current.lowerBound
                pan(by: -Double(dx) / Double(max(chartWidth, 1)) * span, length: length)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }
}
