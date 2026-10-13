import AppKit
import BaseCampCore
import BaseCampDEM
import BaseCampIMG
import MapKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Anything selectable in the sidebar and on the map.
enum LibraryItem: Hashable {
    case waypoint(UUID)
    case route(UUID)
    case track(UUID)
}

/// The planning library shown in the window, plus its selection, undo history and map camera.
@MainActor
@Observable
final class LibraryStore {
    /// The library and its undo history. Every change is saved straight away, so the library survives quitting.
    private var history = UndoHistory(Library())
    var library: Library { history.value }
    /// Goes up by one with every change to the library, so a view can keep work built from it until it changes.
    private(set) var revision = 0
    /// Counts requests to rename the collection being shown. The sidebar watches it. Not saved.
    var renameRequests = 0
    /// The collection the sidebar shows, or nil for every item. Not saved.
    var activeCollectionID: UUID?
    /// Whether the sidebar lists the items or shows them in a table. Not saved.
    var sidebarStyle = SidebarStyle.list
    /// Everything selected in the sidebar. The inspector shows the item when exactly one is selected.
    var selectedItems: Set<LibraryItem> = []
    /// The single selected item, or nil when nothing or several items are selected.
    var selection: LibraryItem? {
        get { selectedItems.count == 1 ? selectedItems.first : nil }
        set { selectedItems = newValue.map { [$0] } ?? [] }
    }
    /// The point under the cursor of an elevation profile, marked on the map. Not saved.
    var profileCoordinate: Coordinate?
    /// Bumped each time the map should frame `fitCoordinates`.
    var fitRequest = 0
    /// Read only when the map is refitted (see `fitRequest`), so changing it does not redraw the views that read the library.
    @ObservationIgnored var fitCoordinates: [Coordinate] = []
    var errorMessage: String?
    var showActivities = false
    var showMaps = false
    var showFind = false

    private let fileURL: URL
    /// Writes the library in the background, after changes settle (see `LibrarySaver`).
    private let saver: LibrarySaver

    init(fileURL: URL = LibraryStore.defaultFileURL) {
        self.fileURL = fileURL
        saver = LibrarySaver(fileURL: fileURL)
        saver.onError = { [weak self] error in
            let message = error is LibrarySaver.BackupError
                ? error.localizedDescription
                : "The library could not be saved. \(error.localizedDescription)"
            Task { @MainActor in
                self?.errorMessage = message
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let stored = try LibraryFile.read(from: fileURL)
            history = UndoHistory(stored.library)
            if stored.version < LibraryFile.currentVersion {
                // The next save writes the new format, which older versions of the app cannot read. Keep the
                // file as it was, once, so going back to an older version stays possible.
                let copy = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("Library-v\(stored.version).json")
                if !FileManager.default.fileExists(atPath: copy.path) {
                    try? FileManager.default.copyItem(at: fileURL, to: copy)
                }
            }
        } catch {
            // Keep the unreadable file, so the next save cannot overwrite it with an empty library.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("Library-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            errorMessage = "The saved library could not be read and was moved to \(backup.lastPathComponent). \(error.localizedDescription)"
        }
    }

    nonisolated static var defaultFileURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("BaseCampClone/Library.json")
    }

    /// Schedules the library for saving. The write happens shortly after the changes settle.
    private func save() {
        saver.schedule(library)
    }

    /// Writes any change still waiting to be saved, now. Called when the app quits.
    func flushSaving() {
        do {
            try saver.flush()
        } catch {
            FileHandle.standardError.write(Data("The library could not be saved at quit. \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: Undo and redo

    var undoName: String? { history.undoName }
    var redoName: String? { history.redoName }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        if history.undo() {
            didChangeLibrary()
        }
    }

    func redo() {
        if history.redo() {
            didChangeLibrary()
        }
    }

    /// Applies one change to the library as one undoable step. Nothing happens if the change does nothing.
    private func edit(_ name: String, coalesceKey: String? = nil, _ change: (inout Library) -> Void) {
        // Work out the new library first. The history is only written when something changes, because writing
        // to it notifies every view that reads the library, even when nothing is different.
        var updated = history.value
        change(&updated)
        guard updated != history.value else { return }
        history.edit(name, coalesceKey: coalesceKey) { $0 = updated }
        didChangeLibrary()
    }

    private func didChangeLibrary() {
        revision += 1
        save()
        clearMissingSelection()
    }

    private func clearMissingSelection() {
        selectedItems = selectedItems.filter { exists($0) }
    }

    private func exists(_ item: LibraryItem) -> Bool {
        switch item {
        case .waypoint(let id): library.waypoints.contains { $0.id == id }
        case .route(let id): library.routes.contains { $0.id == id }
        case .track(let id): library.tracks.contains { $0.id == id }
        }
    }

    // MARK: Import and export

    /// The file types the importer reads, by extension.
    static let importExtensions = ["gpx", "kml", "tcx", "fit"]

    private var importTypes: [UTType] {
        Self.importExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Imports GPX (waypoints, routes, tracks) and FIT (a track from an activity or course) files, as one step.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var imported = Library()
        var messages: [String] = []
        var skippedPoints = 0
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                switch url.pathExtension.lowercased() {
                case "fit":
                    let stem = url.deletingPathExtension().lastPathComponent
                    imported.tracks.append(try FITActivity.read(data, name: stem))
                case "kml":
                    imported.merge(try KML.read(data))
                case "tcx":
                    imported.merge(try TCX.read(data))
                default:
                    let gpx = try GPX.read(data)
                    imported.merge(gpx.library)
                    skippedPoints += gpx.skipped
                }
            } catch {
                messages.append("Could not import \(url.lastPathComponent). \(error.localizedDescription)")
            }
        }
        edit("Import") { $0.merge(imported) }
        if skippedPoints > 0 {
            messages.append("\(skippedPoints) \(skippedPoints == 1 ? "point was" : "points were") skipped because their latitude or longitude is missing or out of range.")
        }
        if !messages.isEmpty {
            errorMessage = messages.joined(separator: "\n")
        }
        fitCamera()
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = importTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// The formats the library and the selection can be saved in.
    enum ExportFormat: CaseIterable, Identifiable {
        case gpx
        case kml
        case csv
        case tcxCourse
        case fitCourse

        var id: Self { self }

        var label: String {
            switch self {
            case .gpx: "GPX (whole library)…"
            case .kml: "KML (whole library)…"
            case .csv: "CSV, waypoints (whole library)…"
            case .tcxCourse: "TCX course (selected route or track)…"
            case .fitCourse: "FIT course (selected route or track)…"
            }
        }

        /// Whether the export works on the selected route or track instead of the whole library.
        var needsSelection: Bool {
            self == .tcxCourse || self == .fitCourse
        }

        var fileExtension: String {
            switch self {
            case .gpx: "gpx"
            case .kml: "kml"
            case .csv: "csv"
            case .tcxCourse: "tcx"
            case .fitCourse: "fit"
            }
        }
    }

    /// Asks where to save, then writes the library or the selected route or track in `format`.
    func export(_ format: ExportFormat) {
        let name: String
        let data: Data
        do {
            if format.needsSelection {
                guard let course = selectedCourse() else {
                    errorMessage = "Select a route or track to export as a course."
                    return
                }
                name = course.name
                data = format == .tcxCourse
                    ? TCX.course(name: course.name, points: course.points)
                    : try FITCourse.encode(name: course.name, points: course.points)
            } else {
                name = "Library"
                switch format {
                case .gpx: data = try GPX.write(library)
                case .kml: data = KML.write(library, name: name)
                case .csv: data = CSV.waypoints(library.waypoints)
                default: data = Data()
                }
            }
        } catch {
            errorMessage = "Could not export. \(error.localizedDescription)"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(FITCourse.fileName(for: name).dropLast(4)).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Could not export to \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    /// Whether a route or track is selected, so a course can be exported.
    var hasCourseSelection: Bool {
        selectedCourse() != nil
    }

    /// The selected route or track as course points, with its name.
    private func selectedCourse() -> (name: String, points: [CoursePoint])? {
        switch selection {
        case .route(let id)?:
            guard let route = route(id) else { return nil }
            return (route.name, route.coursePoints)
        case .track(let id)?:
            guard let track = track(id) else { return nil }
            return (track.name, track.coursePoints)
        default:
            return nil
        }
    }

    /// Measure mode: clicks on the map add points, and the distance along them is shown. Not saved.
    var measuring = false
    var measurePoints: [Coordinate] = []

    /// The length of the measured line, in metres.
    var measuredDistance: Double {
        zip(measurePoints, measurePoints.dropFirst()).reduce(0) { total, pair in
            total + Geodesy.distance(from: pair.0, to: pair.1)
        }
    }

    func toggleMeasuring() {
        measuring.toggle()
        if !measuring {
            measurePoints = []
        }
    }

    /// Fills in heights for the selected track, route or waypoint from the elevation models in `folder`.
    /// With `replaceExisting` false, only points without a height are filled.
    func fillElevationsFromModel(folder: URL, replaceExisting: Bool) {
        guard let selection else { return }
        switch selection {
        case .track(let id):
            guard let track = track(id) else { return }
            Task {
                do {
                    let result = try await Task.detached {
                        try ElevationModel(folder: folder).track(track, replaceExisting: replaceExisting)
                    }.value
                    guard result.filled > 0 else {
                        errorMessage = result.missing == 0 && !replaceExisting
                            ? "Every point of this track already has a height. Use Replace to take heights from the model."
                            : "No elevation model in \(folder.lastPathComponent) covers this track."
                        return
                    }
                    var applied = false
                    edit("Elevations from Model") { library in
                        guard let index = library.tracks.firstIndex(where: { $0.id == id }),
                              let updated = library.tracks[index].applyingElevations(from: result.item, computedFrom: track) else { return }
                        library.tracks[index] = updated
                        applied = true
                    }
                    if !applied {
                        errorMessage = "The track changed while heights were being read; try again."
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .route(let id):
            guard let route = route(id) else { return }
            Task {
                do {
                    let result = try await Task.detached {
                        try ElevationModel(folder: folder).route(route, replaceExisting: replaceExisting)
                    }.value
                    guard result.filled > 0 else {
                        errorMessage = result.missing == 0 && !replaceExisting
                            ? "Every point of this route already has a height. Use Replace to take heights from the model."
                            : "No elevation model in \(folder.lastPathComponent) covers this route."
                        return
                    }
                    var applied = false
                    edit("Elevations from Model") { library in
                        guard let index = library.routes.firstIndex(where: { $0.id == id }),
                              let updated = library.routes[index].applyingElevations(from: result.item, computedFrom: route) else { return }
                        library.routes[index] = updated
                        applied = true
                    }
                    if !applied {
                        errorMessage = "The route changed while heights were being read; try again."
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .waypoint(let id):
            guard let coordinate = waypoint(id)?.coordinate else { return }
            Task {
                do {
                    let height = try await Task.detached {
                        try ElevationModel(folder: folder).elevation(at: coordinate)
                    }.value
                    guard let height else {
                        errorMessage = "No elevation model in \(folder.lastPathComponent) covers this waypoint."
                        return
                    }
                    updateWaypoint(id, field: "elevation") { $0.elevation = height }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Selects the first waypoint, route or track with this name, optionally keeping the current selection.
    func selectItem(named name: String, addingToSelection: Bool = false) {
        var item: LibraryItem?
        if let waypoint = library.waypoints.first(where: { $0.name == name }) {
            item = .waypoint(waypoint.id)
        } else if let route = library.routes.first(where: { $0.name == name }) {
            item = .route(route.id)
        } else if let track = library.tracks.first(where: { $0.name == name }) {
            item = .track(track.id)
        }
        guard let item else { return }
        if addingToSelection {
            selectedItems.insert(item)
        } else {
            selection = item
        }
    }

    /// The centre of the map on screen, to bias place searches. Not saved.
    @ObservationIgnored var viewCenter: Coordinate?
    /// The area of the map on screen. Not saved.
    @ObservationIgnored var viewBounds: GeoBounds?
    /// Bumped to ask the map to save its current view as an image.
    var mapImageRequest = 0
    /// Bumped by "Go to My Location"; the map centres on the Mac's position.
    var locateRequest = 0

    /// Adds a waypoint at `coordinate` and selects it.
    func addWaypoint(name: String, coordinate: Coordinate, comment: String? = nil) {
        let waypoint = Waypoint(name: name, coordinate: coordinate, comment: comment)
        edit("Add Waypoint") { $0.waypoints.append(waypoint) }
        selection = .waypoint(waypoint.id)
    }

    /// Adds a planned or imported route and selects it.
    func addRoute(_ route: Route) {
        edit("Add Route") { $0.routes.append(route) }
        selection = .route(route.id)
    }

    /// Adds a track read from the device and selects it.
    func addTrack(_ track: Track) {
        edit("Add Track") { $0.tracks.append(track) }
        selection = .track(track.id)
        fitCamera()
    }

    // MARK: Items

    func waypoint(_ id: UUID) -> Waypoint? {
        library.waypoints.first { $0.id == id }
    }

    func route(_ id: UUID) -> Route? {
        library.routes.first { $0.id == id }
    }

    func track(_ id: UUID) -> Track? {
        library.tracks.first { $0.id == id }
    }

    func name(of item: LibraryItem) -> String {
        switch item {
        case .waypoint(let id): waypoint(id)?.name ?? ""
        case .route(let id): route(id)?.name ?? ""
        case .track(let id): track(id)?.name ?? ""
        }
    }

    func rename(_ item: LibraryItem, to name: String) {
        edit("Rename", coalesceKey: "rename-\(item)") { library in
            switch item {
            case .waypoint(let id):
                if let index = library.waypoints.firstIndex(where: { $0.id == id }) {
                    library.waypoints[index].name = name
                }
            case .route(let id):
                if let index = library.routes.firstIndex(where: { $0.id == id }) {
                    library.routes[index].name = name
                }
            case .track(let id):
                if let index = library.tracks.firstIndex(where: { $0.id == id }) {
                    library.tracks[index].name = name
                }
            }
        }
    }

    /// Changes one or more fields of a waypoint. Typing into the same field is one undo step.
    func updateWaypoint(_ id: UUID, field: String, _ change: @escaping (inout Waypoint) -> Void) {
        edit("Edit Waypoint", coalesceKey: "waypoint-\(id)-\(field)") { library in
            guard let index = library.waypoints.firstIndex(where: { $0.id == id }) else { return }
            change(&library.waypoints[index])
        }
    }

    func deleteSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        edit(items.count == 1 ? "Delete" : "Delete \(items.count) Items") { library in
            for item in items {
                switch item {
                case .waypoint(let id): library.waypoints.removeAll { $0.id == id }
                case .route(let id): library.routes.removeAll { $0.id == id }
                case .track(let id): library.tracks.removeAll { $0.id == id }
                }
            }
            library.pruneCollections()
        }
        selectedItems = []
    }

    /// The selected tracks, in the order they appear in the library.
    var selectedTracks: [Track] {
        library.tracks.filter { selectedItems.contains(.track($0.id)) }
    }

    /// Joins the selected tracks, in library order, into one track that takes the first one's place.
    func combineSelectedTracks() {
        let tracks = selectedTracks
        guard tracks.count >= 2, let first = tracks.first else { return }
        let combined = Track.combined(tracks, name: first.name)
        edit("Combine Tracks") { $0.combineTracks(tracks.map(\.id), into: combined) }
        selection = .track(combined.id)
    }

    // MARK: Collections

    /// The items of one collection, as library items.
    func items(in collection: LibraryCollection) -> Set<LibraryItem> {
        Set(collection.items.map { item in
            switch item {
            case .waypoint(let id): LibraryItem.waypoint(id)
            case .route(let id): LibraryItem.route(id)
            case .track(let id): LibraryItem.track(id)
            }
        })
    }

    /// Creates an empty collection and shows it in the sidebar. Its name is numbered when others have taken it.
    func createCollection() {
        let collection = LibraryCollection(name: library.nextCollectionName())
        edit("New Collection") { $0.collections.append(collection) }
        activeCollectionID = collection.id
    }

    /// Adds the selected items to a collection. Items already in it are not added twice.
    func addSelection(toCollection id: UUID) {
        let items = selectedItems.compactMap { item -> CollectionItem? in
            switch item {
            case .waypoint(let itemID): .waypoint(itemID)
            case .route(let itemID): .route(itemID)
            case .track(let itemID): .track(itemID)
            }
        }
        edit("Add to Collection") { library in
            guard let index = library.collections.firstIndex(where: { $0.id == id }) else { return }
            for item in items where !library.collections[index].items.contains(item) {
                library.collections[index].items.append(item)
            }
        }
    }

    /// Removes the selected items from the collection being shown.
    func removeSelectionFromActiveCollection() {
        guard let id = activeCollectionID else { return }
        let items = selectedItems.compactMap { item -> CollectionItem? in
            switch item {
            case .waypoint(let itemID): .waypoint(itemID)
            case .route(let itemID): .route(itemID)
            case .track(let itemID): .track(itemID)
            }
        }
        edit("Remove from Collection") { library in
            guard let index = library.collections.firstIndex(where: { $0.id == id }) else { return }
            library.collections[index].items.removeAll { items.contains($0) }
        }
    }

    /// Sets the colour a track or route is drawn in. Nil goes back to the default. Choosing colours in a row is one undo step.
    func setColor(of item: LibraryItem, to color: ItemColor?) {
        edit("Change Colour", coalesceKey: "color-\(item)") { library in
            switch item {
            case .track(let id):
                guard let index = library.tracks.firstIndex(where: { $0.id == id }) else { return }
                library.tracks[index].color = color
            case .route(let id):
                guard let index = library.routes.firstIndex(where: { $0.id == id }) else { return }
                library.routes[index].color = color
            case .waypoint:
                return
            }
        }
    }

    /// Renames a collection. Typing into the name is one undo step.
    func renameCollection(_ id: UUID, to name: String) {
        edit("Rename Collection", coalesceKey: "collection-\(id)") { library in
            _ = library.renameCollection(id, to: name)
        }
    }

    /// Asks the sidebar to show the rename sheet for the collection being shown.
    func requestRenameCollection() {
        renameRequests += 1
    }

    /// Deletes a collection. The items in it stay in the library.
    func deleteCollection(_ id: UUID) {
        edit("Delete Collection") { $0.collections.removeAll { $0.id == id } }
        if activeCollectionID == id {
            activeCollectionID = nil
        }
    }

    /// Frames the map on the selected items. Nothing happens when nothing is selected.
    func zoomToSelection() {
        var coordinates: [Coordinate] = []
        for item in selectedItems {
            switch item {
            case .waypoint(let id): coordinates += waypoint(id).map { [$0.coordinate] } ?? []
            case .route(let id): coordinates += route(id)?.points.map(\.coordinate) ?? []
            case .track(let id): coordinates += track(id)?.segments.flatMap { $0.map(\.coordinate) } ?? []
            }
        }
        guard !coordinates.isEmpty else { return }
        fitCoordinates = coordinates
        fitRequest += 1
    }

    // MARK: Editing tracks and routes

    /// Runs `transform` on the selected track or route, as one undoable step. Other selections are ignored.
    private func editSelection(_ name: String, track: (Track) -> Track, route: (Route) -> Route) {
        switch selection {
        case .track(let id)?:
            edit(name) { library in
                guard let index = library.tracks.firstIndex(where: { $0.id == id }) else { return }
                library.tracks[index] = track(library.tracks[index])
            }
        case .route(let id)?:
            edit(name) { library in
                guard let index = library.routes.firstIndex(where: { $0.id == id }) else { return }
                library.routes[index] = route(library.routes[index])
            }
        default:
            break
        }
    }

    func reverseSelection() {
        editSelection("Reverse", track: { $0.reversed() }, route: { $0.reversed() })
    }

    /// Keeps the shape to within `tolerance` metres and drops the rest of the points.
    func simplifySelection(tolerance: Double) {
        editSelection("Simplify", track: { $0.simplified(tolerance: tolerance) }, route: { $0.simplified(tolerance: tolerance) })
    }

    /// Moves one stop of a route, for example by dragging it on the map. The legs on either side become straight
    /// until they are recalculated (see `Route.moveStop`).
    func moveRouteStop(_ id: UUID, at index: Int, to coordinate: Coordinate) {
        edit("Move Point") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == id }) else { return }
            library.routes[routeIndex].moveStop(at: index, to: coordinate)
        }
    }

    /// Inserts a stop into a route at `index`, for example by dragging the handle in the middle of a leg. The legs
    /// it splits become straight until they are recalculated.
    func insertRouteStop(_ id: UUID, at index: Int, coordinate: Coordinate) {
        edit("Insert Point") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == id }) else { return }
            library.routes[routeIndex].insertStop(RouteStop(coordinate: coordinate), at: index)
        }
    }

    /// Adds a stop after the end of a route.
    func extendRoute(_ id: UUID, to coordinate: Coordinate) {
        edit("Extend Route") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == id }) else { return }
            library.routes[routeIndex].insertStop(RouteStop(coordinate: coordinate), at: library.routes[routeIndex].stops.count)
        }
    }

    /// Puts in a leg the router recalculated, as part of the step that changed its stops: undo takes back both.
    /// Nothing happens when the leg's stops changed in the meantime. Returns whether the leg was taken.
    @discardableResult
    func applyRecalculatedLeg(_ id: UUID, at index: Int, from start: RouteStop, to end: RouteStop, _ leg: RouteLeg) -> Bool {
        var taken = false
        let changed = history.amend { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == id }) else { return }
            taken = library.routes[routeIndex].setLeg(at: index, from: start, to: end, leg)
        }
        if changed {
            revision += 1
            save()
        }
        return taken
    }

    /// Deletes one stop of a route.
    func removeRouteStop(_ id: UUID, at index: Int) {
        edit("Delete Point") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == id }) else { return }
            library.routes[routeIndex].removeStop(at: index)
        }
    }

    /// Renames a stop of a route, as typed: an empty name clears it. Typing into the name is one undo step.
    func renameRouteStop(_ route: UUID, stop: UUID, to name: String) {
        edit("Rename Point", coalesceKey: "route-stop-name-\(stop)") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == route }),
                  let index = library.routes[routeIndex].stops.firstIndex(where: { $0.id == stop }) else { return }
            library.routes[routeIndex].updateStop(at: index) { $0.name = name.isEmpty ? nil : name }
        }
    }

    /// Makes a stop of a route a shaping point or a via point. The first and last stops stay via points.
    func setRouteStopShaping(_ route: UUID, stop: UUID, isShaping: Bool) {
        edit("Change Point Type") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == route }),
                  let index = library.routes[routeIndex].stops.firstIndex(where: { $0.id == stop }) else { return }
            library.routes[routeIndex].setShaping(isShaping, at: index)
        }
    }

    /// Sets the routing profile a route's changed legs are recalculated with. Nothing is recalculated by this.
    func setRouteProfile(_ route: UUID, profileID: UUID?) {
        edit("Change Routing") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == route }) else { return }
            library.routes[routeIndex].profileID = profileID
        }
    }

    /// Joins another track onto the selected track, in order. The result takes the selected track's place and name.
    func combineSelection(withTrack other: UUID) {
        guard case .track(let id)? = selection, id != other,
              let first = track(id), let second = track(other) else { return }
        let combined = Track.combined([first, second], name: first.name)
        edit("Combine Tracks") { $0.combineTracks([id, other], into: combined) }
        selection = .track(combined.id)
    }

    /// Makes a copy of the selected track or route next to it, with a new identifier.
    func duplicateSelection() {
        switch selection {
        case .track(let id)?:
            guard let track = track(id) else { return }
            let copy = Track(name: track.name + " copy", segments: track.segments, color: track.color)
            edit("Duplicate") { $0.tracks.append(copy) }
            selection = .track(copy.id)
        case .route(let id)?:
            guard let route = route(id) else { return }
            var copy = route
            copy.id = UUID()
            copy.name = route.name + " copy"
            edit("Duplicate") { $0.routes.append(copy) }
            selection = .route(copy.id)
        default:
            break
        }
    }

    /// Cuts the selected track in two at the point under the elevation profile's cursor.
    /// Returns false when there is no cursor position or the selection is not a track.
    @discardableResult
    func splitSelectedTrackAtCursor() -> Bool {
        guard case .track(let id)? = selection, let cursor = profileCoordinate,
              let track = track(id), let pieces = track.split(nearest: cursor) else { return false }
        edit("Split Track") { $0.splitTrack(id, into: pieces) }
        selection = .track(pieces.0.id)
        return true
    }

    /// Turns the selected track into a route, or a route into a track. The item keeps its name and points.
    func convertSelection() {
        switch selection {
        case .track(let id)?:
            guard let track = track(id) else { return }
            let route = track.asRoute()
            edit("Convert to Route") { $0.convertTrack(id, to: route) }
            selection = .route(route.id)
        case .route(let id)?:
            guard let route = route(id) else { return }
            let track = route.asTrack()
            edit("Convert to Track") { $0.convertRoute(id, to: track) }
            selection = .track(track.id)
        default:
            break
        }
    }

    // MARK: Map

    /// Asks the map to frame everything in the library.
    func fitCamera() {
        fitCoordinates = library.coordinates
        fitRequest += 1
    }
}
