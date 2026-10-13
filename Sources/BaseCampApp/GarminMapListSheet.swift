import BaseCampCore
import SwiftUI

/// The Garmin map list, as QMapShack's: which maps are drawn, in which order, between which zoom levels, and how
/// opaque. The top map is drawn on top.
struct GarminMapListSheet: View {
    @Environment(GarminMapListStore.self) private var maps
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Garmin Maps")
                .font(.title2.bold())
            Text("Maps higher in the list are drawn on top. Drag to reorder. Overlays, such as contour maps, are drawn without a background.")
                .foregroundStyle(.secondary)
            if let problem = maps.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let folder = maps.folder {
                Text("Map folder: \(folder.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if maps.entries.isEmpty {
                ContentUnavailableView("No maps", systemImage: "map", description: Text("Put .img maps in the map folder, chosen in Settings."))
            } else {
                List {
                    ForEach(maps.topFirst) { entry in
                        row(entry)
                    }
                    .onMove { maps.moveTopFirst(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 860, height: 480)
    }

    private func row(_ entry: MapListEntry) -> some View {
        HStack(spacing: 16) {
            Toggle(isOn: Binding(get: { entry.isEnabled }, set: { maps.setEnabled($0, for: entry.fileName) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((entry.fileName as NSString).deletingPathExtension)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.fileName)
                    Text(entry.isOverlay ? "Overlay" : "Map")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 260, alignment: .leading)
            Spacer()
            zoomPicker("From", value: entry.minimumZoom) {
                maps.setZoomRange(minimum: $0, maximum: entry.maximumZoom, for: entry.fileName)
            }
            zoomPicker("to", value: entry.maximumZoom) {
                maps.setZoomRange(minimum: entry.minimumZoom, maximum: $0, for: entry.fileName)
            }
            HStack(spacing: 4) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { entry.opacity }, set: { maps.setOpacity($0, for: entry.fileName) }), in: 0.1...1)
                    .frame(width: 90)
            }
            .help("Opacity")
        }
        .padding(.vertical, 2)
    }

    private func zoomPicker(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            ForEach(0...MapList.closestZoom, id: \.self) { zoom in
                Text(Self.zoomLabel(zoom)).tag(zoom)
            }
        }
        .fixedSize()
        .help("Zoom level, with the map scale at mid-latitudes")
    }

    /// A zoom level with its approximate map scale at 46° latitude, for example "13 · 1:48 000".
    static func zoomLabel(_ zoom: Int) -> String {
        let metersPerPixel = 156_543.03 * cos(46 * Double.pi / 180) / pow(2, Double(zoom))
        // A screen pixel of 0.28 mm, the usual convention for map scales.
        let scale = metersPerPixel / 0.000_28
        let magnitude = pow(10, floor(log10(scale)) - 1)
        let rounded = Int((scale / magnitude).rounded() * magnitude)
        return "\(zoom) · 1:\(rounded.formatted(.number.grouping(.automatic)))"
    }
}
