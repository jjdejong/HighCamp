import AppKit
import BaseCampCore
import SwiftUI

/// Which kinds of points of interest the Garmin maps show: each type the maps' styles define, with its icon, in
/// Garmin's families. A hidden type loses its icon and its name, and leaves its room to the others.
struct POITypesSheet: View {
    @Environment(MapLayerSettings.self) private var mapLayers
    @Environment(GarminMapListStore.self) private var maps
    @Environment(\.dismiss) private var dismiss
    @State private var types: [POIType] = []
    @State private var loaded = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Points of Interest")
                .font(.title2.bold())
            Text("Choose which points the Garmin maps show. A hidden type loses its icon and its name. Below zoom 15, only passes, summits, glaciers and national parks are shown.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Filter by name", text: $search)
                .textFieldStyle(.roundedBorder)
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if types.isEmpty {
                ContentUnavailableView(
                    "No point types", systemImage: "mappin.slash",
                    description: Text("The Garmin maps that are on have no style for their points.")
                )
            } else {
                List {
                    ForEach(groups, id: \.category) { group in
                        Section {
                            ForEach(group.types) { type in
                                row(type)
                            }
                        } header: {
                            header(group.category, types: group.types)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack {
                Button("Show All") { mapLayers.hiddenPointTypes = [] }
                Button("Hide All") { mapLayers.hiddenPointTypes = Set(types.map(\.type)) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 620)
        // Again when the map list has loaded or changed.
        .task(id: mapURLs) {
            types = await MapFeatureCache.shared.pointTypes(maps: mapURLs)
            loaded = true
        }
    }

    private var mapURLs: [URL] {
        mapLayers.garminConfiguration(maps).layers.map(\.url)
    }

    /// The types matching the filter, by family, in the families' order.
    private var groups: [(category: POICategory, types: [POIType])] {
        let wanted = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = types.filter { wanted.isEmpty || Self.title($0).lowercased().contains(wanted) }
        let byCategory = Dictionary(grouping: matching) { POICategory.of($0.type) }
        return POICategory.allCases.compactMap { category in
            byCategory[category].map { (category, $0.sorted { Self.title($0).localizedStandardCompare(Self.title($1)) == .orderedAscending }) }
        }
    }

    private func header(_ category: POICategory, types: [POIType]) -> some View {
        let hidden = types.filter { mapLayers.hiddenPointTypes.contains($0.type) }.count
        return Toggle(isOn: Binding(
            get: { hidden < types.count },
            set: { show in
                if show {
                    mapLayers.hiddenPointTypes.subtract(types.map(\.type))
                } else {
                    mapLayers.hiddenPointTypes.formUnion(types.map(\.type))
                }
            }
        )) {
            Text(category.title)
                .font(.headline)
            + Text(hidden == 0 ? "" : hidden == types.count ? "  all hidden" : "  \(hidden) of \(types.count) hidden")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
    }

    private func row(_ type: POIType) -> some View {
        Toggle(isOn: Binding(
            get: { !mapLayers.hiddenPointTypes.contains(type.type) },
            set: { show in
                if show {
                    mapLayers.hiddenPointTypes.remove(type.type)
                } else {
                    mapLayers.hiddenPointTypes.insert(type.type)
                }
            }
        )) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(cgImage: type.icon.image, size: NSSize(width: type.icon.width, height: type.icon.height)))
                    .interpolation(.none)
                    .frame(width: 26, height: 26)
                Text(Self.title(type))
                Spacer()
                Text(String(format: "0x%04X", type.type))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// The style's name with a capital first letter, or the type number when the style has no name.
    static func title(_ type: POIType) -> String {
        guard let name = type.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return String(format: "Type 0x%04X", type.type)
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
