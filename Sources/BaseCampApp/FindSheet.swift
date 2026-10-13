import BaseCampCore
import MapKit
import SwiftUI

/// Find a place by name, the way BaseCamp's Find does. Results can be added as waypoints or shown on the map.
struct FindSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var isSearching = false
    @State private var message: String?

    /// One search result, reduced to what the sheet shows.
    struct Place: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        let coordinate: Coordinate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Place, address or point of interest", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Find", action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            if isSearching {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity)
            } else if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if results.isEmpty {
                Text("Search for a place. Results near the map are listed first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(results) { place in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            if !place.address.isEmpty {
                                Text(place.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Show") {
                            store.fitCoordinates = [place.coordinate]
                            store.fitRequest += 1
                        }
                        Button("Add Waypoint") {
                            store.addWaypoint(name: place.name, coordinate: place.coordinate, comment: place.address.isEmpty ? nil : place.address)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 560, height: 420)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        message = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let centre = store.viewCenter {
            request.region = MKCoordinateRegion(
                center: centre.clLocation,
                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
            )
        }
        MKLocalSearch(request: request).start { response, error in
            Task { @MainActor in
                isSearching = false
                if let error {
                    results = []
                    message = "Nothing found. \(error.localizedDescription)"
                    return
                }
                results = (response?.mapItems ?? []).map { item in
                    let location = item.placemark.coordinate
                    return Place(
                        name: item.name ?? text,
                        address: [item.placemark.subtitle, item.placemark.title].compactMap { $0 }.first ?? "",
                        coordinate: Coordinate(latitude: location.latitude, longitude: location.longitude)
                    )
                }
                if results.isEmpty {
                    message = "No place matches \"\(text)\"."
                }
            }
        }
    }
}
