import BaseCampCore
import SwiftUI

extension ItemSummary {
    /// The library item this row stands for, as the selection and the rest of the app name it.
    var libraryItem: LibraryItem {
        switch kind {
        case .waypoint: .waypoint(id)
        case .route: .route(id)
        case .track: .track(id)
        }
    }
}

/// The waypoints, routes and tracks as a sortable table: name, type, length, date and ascent.
/// Selecting rows selects them on the map and in the inspector, as the sidebar list does.
struct ItemsTable: View {
    @Environment(DisplaySettings.self) private var display
    let items: [ItemSummary]
    @Binding var selection: Set<LibraryItem>
    /// Called for a double-click, or Zoom to Selection in a row's menu, with the rows it applies to.
    var onOpen: (Set<LibraryItem>) -> Void = { _ in }
    @State private var order = [KeyPathComparator(\ItemRow.summary.name)]

    var body: some View {
        Table(items.map { ItemRow(summary: $0) }.sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.summary.name) { row in
                Text(row.summary.name.isEmpty ? "Unnamed" : row.summary.name)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Type", value: \.summary.kind.rawValue) { row in
                Text(row.summary.kind.rawValue)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Length", value: \.lengthSortKey) { row in
                Text(row.summary.lengthMeters.map { UnitFormat.distance($0, display.units) } ?? "–")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Date", value: \.dateSortKey) { row in
                Text(row.summary.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "–")
            }
            .width(min: 75, ideal: 85)
            TableColumn("Ascent", value: \.ascentSortKey) { row in
                Text(row.summary.ascentMeters.map { UnitFormat.elevation($0, display.units) } ?? "–")
                    .monospacedDigit()
            }
            .width(min: 55, ideal: 60)
        }
        .contextMenu(forSelectionType: LibraryItem.self) { items in
            if !items.isEmpty {
                Button("Zoom to Selection") { onOpen(items) }
            }
        } primaryAction: { items in
            onOpen(items)
        }
    }
}

/// A summary as a table row. The selection uses `LibraryItem`, so the row is identified by it.
private struct ItemRow: Identifiable {
    let summary: ItemSummary
    var id: LibraryItem { summary.libraryItem }

    // Sort keys. A missing figure sorts before every real one, and shows as a dash.
    var lengthSortKey: Double { summary.lengthMeters ?? -1 }
    var ascentSortKey: Double { summary.ascentMeters ?? -1 }
    var dateSortKey: Date { summary.date ?? .distantPast }
}
