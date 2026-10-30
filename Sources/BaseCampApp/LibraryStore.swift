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
    /// The place in the library tree that is selected: its items are listed and drawn on the map, and new items
    /// go into it when it is a list. Not saved.
    var selectedNode = LibraryNode.myCollection
    /// The list or folder being renamed, for the sidebar's rename sheet.
    var renaming: LibraryNode?
    /// Waiting for the user to confirm, for the sidebar's dialogs.
    var pendingNodeRemoval: LibraryNode?
    var pendingListDuplication: UUID?
    var pendingItemDeletion: ItemDeletion?
    /// New items made while a list folder was selected: the user picks a list in it for them.
    var pendingListChoice: ListChoice?

    /// Whether the selected node is a list or folder, which can be renamed and removed.
    var selectedNodeIsEditable: Bool {
        switch selectedNode {
        case .list, .folder: true
        default: false
        }
    }

    /// The list selected in the library tree, if a list is.
    var selectedListID: UUID? {
        if case .list(let id) = selectedNode { return id }
        return nil
    }
    /// Whether the sidebar lists the items or shows them in a table. Not saved.
    var sidebarStyle = SidebarStyle.list
    /// Everything selected in the sidebar. The inspector shows the item when exactly one is selected.
    var selectedItems: Set<LibraryItem> = [] {
        // The profile cursor and a picked stretch belong to the item they were set on.
        didSet {
            if selectedItems != oldValue {
                profileRange = nil
                profileCursor = nil
            }
        }
    }
    /// The single selected item, or nil when nothing or several items are selected.
    var selection: LibraryItem? {
        get { selectedItems.count == 1 ? selectedItems.first : nil }
        set { selectedItems = newValue.map { [$0] } ?? [] }
    }
    /// The stop of the selected route last clicked on the map, highlighted there and in the inspector. Not saved.
    var selectedStop: UUID?
    /// The profile cursor, in metres along the selected track or route. Set by hovering over its profile or over its
    /// line on the map, and kept when the pointer leaves, so it can be used (Split at Profile Position). Not saved.
    var profileCursor: Double?
    /// The place of the profile cursor on the map.
    var profileCoordinate: Coordinate? {
        profileCursor.flatMap { selectedMeasure?.coordinate(at: $0) }
    }
    /// The stretch of the selected track picked by dragging across its profile, in metres from the start. Not saved.
    var profileRange: ClosedRange<Double>?
    /// Distances along the selected track or route, as its profile measures them. Nil for anything else.
    var selectedMeasure: LineMeasure? {
        let key: LibraryItem?
        switch selection {
        case .track?, .route?: key = selection
        default: return nil
        }
        if let cached = measureCache, cached.item == key, cached.revision == revision {
            return cached.measure
        }
        let measure: LineMeasure?
        switch key {
        case .track(let id)?: measure = track(id)?.measure
        case .route(let id)?: measure = route(id)?.measure
        default: measure = nil
        }
        measureCache = measure.map { (key, revision, $0) }
        return measure
    }
    @ObservationIgnored private var measureCache: (item: LibraryItem?, revision: Int, measure: LineMeasure)?
    /// Bumped each time the map should frame `fitCoordinates`.
    var fitRequest = 0
    /// Read only when the map is refitted (see `fitRequest`), so changing it does not redraw the views that read the library.
    @ObservationIgnored var fitCoordinates: [Coordinate] = []
    var errorMessage: String?
    var showActivities = false
    var showMaps = false
    var showFind = false

    private let fileURL: URL
    /// The folder of the library file, where the app keeps what goes with the library (track DEMs, say).
    var dataFolder: URL { fileURL.deletingLastPathComponent() }
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
            // Its lines go with it, or the next save would remove them as no longer used.
            try? LibraryFile.move(fileURL, to: backup)
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
        case .waypoint(let id): waypoint(id) != nil
        case .route(let id): route(id) != nil
        case .track(let id): track(id) != nil
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
        placeNewItems(imported.allItems.map(LibraryItem.init).filter(exists))
        if skippedPoints > 0 {
            messages.append("\(skippedPoints) \(skippedPoints == 1 ? "point was" : "points were") skipped because their latitude or longitude is missing or out of range.")
        }
        if !messages.isEmpty {
            errorMessage = messages.joined(separator: "\n")
        }
        fitCamera()
    }

    /// Imports BaseCamp's own library, with its lists and list folders, as one step. `url` is a `.bclibrary`, BaseCamp's
    /// Database folder, or the version folder in it. The files are read in the background and never written.
    func importBaseCampLibrary(_ url: URL) {
        guard let folder = BaseCampDatabase.databaseFolder(for: url) else {
            errorMessage = "No BaseCamp library in \(url.lastPathComponent). Choose a .bclibrary folder, or BaseCamp's Database folder."
            return
        }
        Task {
            let read = await Task.detached(priority: .userInitiated) { Result { try BaseCampDatabase.read(folder) } }.value
            switch read {
            case .success(let contents):
                let library = contents.library
                edit("Import BaseCamp Library") { $0.mergeWithLists(library) }
                fitCamera()
                var summary = "Imported from BaseCamp: \(library.waypoints.count) waypoints, \(library.routes.count) routes and "
                    + "\(library.tracks.count) tracks, in \(library.collections.count) lists and \(library.folders.count) folders."
                if contents.unreadable > 0 {
                    summary += " \(contents.unreadable) \(contents.unreadable == 1 ? "item" : "items") could not be read."
                }
                errorMessage = summary
            case .failure(let error):
                errorMessage = "Could not import the BaseCamp library. \(error.localizedDescription)"
            }
        }
    }

    func showBaseCampImportPanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose BaseCamp's library: a .bclibrary folder, or BaseCamp's Database folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        let own = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Garmin/BaseCamp/Database")
        if FileManager.default.fileExists(atPath: own.path) {
            panel.directoryURL = own
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importBaseCampLibrary(url)
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
            case .gpx: "GPX (selected list or folder)…"
            case .kml: "KML (selected list or folder)…"
            case .csv: "CSV, waypoints (selected list or folder)…"
            case .tcxCourse: "TCX course (selected route or track)…"
            case .fitCourse: "FIT course (selected route or track)…"
            }
        }

        /// Whether the export works on the selected route or track instead of the node selected in the library tree.
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
                // The node selected in the library tree, named after it, as BaseCamp exports a list.
                guard let part = library(of: selectedNode), !part.isEmpty else {
                    errorMessage = "\(self.name(of: selectedNode)) has nothing to export."
                    return
                }
                name = self.name(of: selectedNode)
                switch format {
                case .gpx: data = try GPX.write(part)
                case .kml: data = KML.write(part, name: name)
                case .csv: data = CSV.waypoints(part.waypoints)
                default: data = Data()
                }
            }
        } catch {
            errorMessage = "Could not export. \(error.localizedDescription)"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = format.needsSelection
            ? "\(FITCourse.fileName(for: name).dropLast(4)).\(format.fileExtension)"
            : "\(Self.diskFileName(name)).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Could not export to \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    /// The items of a node of the library tree, as a library of their own, in My Collection's order. Nil for the
    /// device's folders.
    func library(of node: LibraryNode) -> Library? {
        if case .device = node { return nil }
        let wanted = items(of: node)
        let keep = { (item: LibraryItem) in wanted?.contains(item) ?? true }
        return Library(
            waypoints: library.waypoints.filter { keep(.waypoint($0.id)) },
            routes: library.routes.filter { keep(.route($0.id)) },
            tracks: library.tracks.filter { keep(.track($0.id)) }
        )
    }

    /// A list's name as a file name on disk: only "/" and ":" are left out.
    static func diskFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Library" : cleaned
    }

    /// The selected node as one GPX file for the device, named after it, or nil (with a message) when it is empty.
    func gpxForDevice() -> (fileName: String, data: Data)? {
        guard let part = library(of: selectedNode), !part.isEmpty else {
            errorMessage = "\(name(of: selectedNode)) has nothing to send."
            return nil
        }
        return (FITCourse.fileName(for: name(of: selectedNode)).dropLast(4) + ".gpx", GPX.write(part))
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

    /// Where heights come from: the elevation folder and the Garmin maps that are on. Set by the main view.
    @ObservationIgnored var heightSources: HeightSources?

    /// Fills in heights for the selected track, route or waypoint from the elevation models and the Garmin maps'
    /// heights (see `HeightSources`), or from the item's own track DEM when `trackDEM` is given. With
    /// `replaceExisting` false, only points without a height are filled.
    func fillElevationsFromModel(trackDEM: URL? = nil, replaceExisting: Bool) {
        guard let selection, var sources = heightSources else { return }
        if let trackDEM {
            sources.folder = trackDEM
            sources.mapsFirst = false
        }
        let nothing = sources.maps.isEmpty
            ? "No elevation model in \(sources.folder.lastPathComponent) covers this"
            : "Neither the elevation models in \(sources.folder.lastPathComponent) nor the Garmin maps have heights for this"
        switch selection {
        case .track(let id):
            guard let track = track(id) else { return }
            Task {
                let result = track.withElevations(await sources.heights(for: track.allCoordinates), replaceExisting: replaceExisting)
                guard result.filled > 0 else {
                    errorMessage = result.missing == 0 && !replaceExisting
                        ? "Every point of this track already has a height. Use Replace to take heights from the model."
                        : "\(nothing) track."
                    return
                }
                var applied = false
                edit("Elevations from Model") { library in
                    guard let index = library.tracks.firstIndex(where: { $0.id == id }),
                          let updated = library.tracks[index].applyingElevations(from: result.0, computedFrom: track) else { return }
                    library.tracks[index] = updated
                    applied = true
                }
                if !applied {
                    errorMessage = "The track changed while heights were being read; try again."
                }
            }
        case .route(let id):
            guard let route = route(id) else { return }
            Task {
                let result = route.withElevations(
                    await sources.heights(for: route.points.map(\.coordinate)), replaceExisting: replaceExisting
                )
                guard result.filled > 0 else {
                    errorMessage = result.missing == 0 && !replaceExisting
                        ? "Every point of this route already has a height. Use Replace to take heights from the model."
                        : "\(nothing) route."
                    return
                }
                var applied = false
                edit("Elevations from Model") { library in
                    guard let index = library.routes.firstIndex(where: { $0.id == id }),
                          let updated = library.routes[index].applyingElevations(from: result.0, computedFrom: route) else { return }
                    library.routes[index] = updated
                    applied = true
                }
                if !applied {
                    errorMessage = "The route changed while heights were being read; try again."
                }
            }
        case .waypoint(let id):
            guard let coordinate = waypoint(id)?.coordinate else { return }
            Task {
                guard let height = await sources.heights(for: [coordinate]).first ?? nil else {
                    errorMessage = "\(nothing) waypoint."
                    return
                }
                updateWaypoint(id, field: "elevation") { $0.elevation = height }
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
        placeNewItems([.waypoint(waypoint.id)])
        selection = .waypoint(waypoint.id)
        // Its height, as BaseCamp gives one, read after it is added so it shows at once. Undo takes both back.
        guard let sources = heightSources else { return }
        Task {
            guard let height = await sources.heights(for: [coordinate]).first ?? nil else { return }
            let changed = history.amend { library in
                guard let index = library.waypoints.firstIndex(where: { $0.id == waypoint.id }),
                      library.waypoints[index].elevation == nil, library.waypoints[index].coordinate == coordinate else { return }
                library.waypoints[index].elevation = height
            }
            if changed {
                revision += 1
                save()
            }
        }
    }

    /// Adds a planned or imported route and selects it.
    func addRoute(_ route: Route) {
        edit("Add Route") { $0.routes.append(route) }
        placeNewItems([.route(route.id)])
        selection = .route(route.id)
    }

    /// Adds a track read from the device and selects it.
    func addTrack(_ track: Track) {
        edit("Add Track") { $0.tracks.append(track) }
        placeNewItems([.track(track.id)])
        selection = .track(track.id)
        fitCamera()
    }

    // MARK: Items

    /// A waypoint of the library, or of the connected device.
    func waypoint(_ id: UUID) -> Waypoint? {
        library.waypoints.first { $0.id == id } ?? deviceItems.waypoints.first { $0.id == id }
    }

    func route(_ id: UUID) -> Route? {
        library.routes.first { $0.id == id } ?? deviceItems.routes.first { $0.id == id }
    }

    func track(_ id: UUID) -> Track? {
        library.tracks.first { $0.id == id } ?? deviceItems.tracks.first { $0.id == id }
    }

    // MARK: The device's items

    /// What is on the connected device, by folder (see `DeviceContents`). Set by the main view. Its items can be
    /// selected, shown and measured like the library's, but not changed: they are copied to the library for that.
    var device = DeviceContents() {
        didSet {
            guard device != oldValue else { return }
            deviceItems = device.library
            deviceRevision += 1
            measureCache = nil
            clearMissingSelection()
        }
    }
    /// Every item on the device, for looking items up.
    private(set) var deviceItems = Library()
    /// Bumped when the device's items change, so the map draws them again.
    private(set) var deviceRevision = 0

    /// The device's folders drawn on the map. Activities are not, until asked: a device holds hundreds.
    var deviceGroupsOnMap: Set<String> = LibraryStore.savedDeviceGroupsOnMap() {
        didSet { UserDefaults.standard.set(deviceGroupsOnMap.sorted(), forKey: "device.groupsOnMap") }
    }

    private static func savedDeviceGroupsOnMap() -> Set<String> {
        if let saved = UserDefaults.standard.array(forKey: "device.groupsOnMap") as? [String] {
            return Set(saved)
        }
        return Set(DeviceGroup.Kind.allCases.filter(\.shownOnMapByDefault).map(\.rawValue))
    }

    /// Whether the item is on the device rather than in the library.
    func isOnDevice(_ item: LibraryItem) -> Bool {
        switch item {
        case .waypoint(let id): !library.waypoints.contains { $0.id == id } && deviceItems.waypoints.contains { $0.id == id }
        case .route(let id): !library.routes.contains { $0.id == id } && deviceItems.routes.contains { $0.id == id }
        case .track(let id): !library.tracks.contains { $0.id == id } && deviceItems.tracks.contains { $0.id == id }
        }
    }

    /// The device's folder an item is in.
    func deviceGroup(of item: LibraryItem) -> DeviceGroup? {
        device.groups.first { $0.items.contains(item) }
    }

    /// Files waiting for the user to confirm they are deleted from the device. Set by `deleteSelection` and
    /// "Delete from Device"; the main view asks.
    var pendingDeviceDeletion: [DeviceFileRef]?

    /// The device files the items were read from, each once, in the device's order.
    func deviceFiles(of items: Set<LibraryItem>) -> [DeviceFileRef] {
        var found: [DeviceFileRef] = []
        for group in device.groups {
            for item in group.items where items.contains(item) {
                if let file = group.files[item] {
                    if !found.contains(file) { found.append(file) }
                }
            }
        }
        return found
    }

    /// The items read from a device file: what deleting it takes away.
    func deviceItems(in file: DeviceFileRef) -> [LibraryItem] {
        guard let group = device.groups.first(where: { $0.kind == file.kind }) else { return [] }
        return group.items.filter { group.files[$0] == file }
    }

    /// Asks to delete the files of the selected device items from the device. Saved locations are left out: they
    /// share one file, so they are deleted on the device itself.
    func requestDeviceDeletion(_ items: Set<LibraryItem>) {
        let all = deviceFiles(of: items)
        let files = all.filter(\.kind.canDeleteFiles)
        if !files.isEmpty {
            pendingDeviceDeletion = files
        } else if !all.isEmpty {
            errorMessage = "\(device.deviceName) keeps all its saved locations in one file, so they are deleted on the device itself, in Saved Locations."
        }
    }

    /// Copies items from the device into the library, as new items, and selects the copies.
    func copyToLibrary(_ items: Set<LibraryItem>) {
        var copies: Set<LibraryItem> = []
        var waypoints: [Waypoint] = [], routes: [Route] = [], tracks: [Track] = []
        for item in items where isOnDevice(item) {
            switch item {
            case .waypoint(let id):
                guard var copy = waypoint(id) else { continue }
                copy.id = UUID()
                waypoints.append(copy)
                copies.insert(.waypoint(copy.id))
            case .route(let id):
                guard var copy = route(id) else { continue }
                copy.id = UUID()
                routes.append(copy)
                copies.insert(.route(copy.id))
            case .track(let id):
                guard var copy = track(id) else { continue }
                copy.id = UUID()
                tracks.append(copy)
                copies.insert(.track(copy.id))
            }
        }
        guard !copies.isEmpty else { return }
        edit(copies.count == 1 ? "Copy to Library" : "Copy \(copies.count) Items to Library") { library in
            library.waypoints += waypoints
            library.routes += routes
            library.tracks += tracks
        }
        placeNewItems(Array(copies))
        selectedItems = copies
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

    /// Deletes the selected library items. Selected device items are not deleted here: their files are deleted
    /// from the device once the user confirms (see `pendingDeviceDeletion`).
    func deleteSelection() {
        requestDeviceDeletion(selectedItems.filter(isOnDevice))
        let items = selectedItems.filter { !isOnDevice($0) }
        guard !items.isEmpty else { return }
        // In a list, BaseCamp asks whether to take the items out of the list or delete them from My Collection. In
        // My Collection, items in lists are deleted from all of them, so it warns first.
        if let list = selectedListID {
            pendingItemDeletion = ItemDeletion(items: items, list: list)
            return
        }
        if items.contains(where: { !library.lists(containing: CollectionItem($0)).isEmpty }) {
            pendingItemDeletion = ItemDeletion(items: items, list: nil)
            return
        }
        deleteFromMyCollection(items)
    }

    /// Deletes items from My Collection, and so from every list.
    func deleteFromMyCollection(_ items: Set<LibraryItem>) {
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
        selectedItems.subtract(items)
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
        Set(collection.items.map(LibraryItem.init))
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

    // MARK: Lists and list folders, as BaseCamp organises My Collection

    /// The items a node of the library tree holds, or nil for My Collection (every item).
    func items(of node: LibraryNode) -> Set<LibraryItem>? {
        switch node {
        case .myCollection: nil
        case .unlisted: Set(library.unlistedItems.map(LibraryItem.init))
        case .folder(let id): Set(library.items(inFolder: id).map(LibraryItem.init))
        case .list(let id): library.collections.first { $0.id == id }.map(items(in:)) ?? []
        case .device(let kind): Set(device.groups.first { $0.kind == kind }?.items ?? [])
        }
    }

    /// The folder new lists and folders go into: the selected folder, or the folder of the selected list.
    private var folderForNewNodes: UUID? {
        switch selectedNode {
        case .folder(let id): id
        case .list(let id): library.collections.first { $0.id == id }?.folderID
        default: nil
        }
    }

    /// A list's place, as "Folder › Sub-folder › List".
    func path(ofList id: UUID) -> String {
        guard let list = library.collections.first(where: { $0.id == id }) else { return "" }
        var names = [list.name]
        var folder = list.folderID
        var seen: Set<UUID> = []
        while let id = folder, !seen.contains(id), let found = library.folders.first(where: { $0.id == id }) {
            seen.insert(id)
            names.insert(found.name, at: 0)
            folder = found.parentID
        }
        return names.joined(separator: " › ")
    }

    /// Every list with its place, by place, for menus.
    var listsByPath: [(id: UUID, path: String)] {
        library.collections.map { ($0.id, path(ofList: $0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Adds a list ("New List") to the selected folder, selects it and asks for its name.
    func newList() {
        let folder = folderForNewNodes
        var id: UUID?
        edit("New List") { id = $0.createList(in: folder) }
        if let id {
            selectedNode = .list(id)
            renaming = .list(id)
        }
    }

    /// Adds a list folder ("New Folder") to the selected folder, selects it and asks for its name.
    func newFolder() {
        let parent = folderForNewNodes
        var id: UUID?
        edit("New List Folder") { id = $0.createFolder(in: parent) }
        if let id {
            selectedNode = .folder(id)
            renaming = .folder(id)
        }
    }

    /// The name of a list or folder.
    func name(of node: LibraryNode) -> String {
        switch node {
        case .myCollection: "My Collection"
        case .unlisted: "Unlisted Data"
        case .folder(let id): library.folders.first { $0.id == id }?.name ?? ""
        case .list(let id): library.collections.first { $0.id == id }?.name ?? ""
        case .device(let kind): kind.title
        }
    }

    /// Renames a list or folder. Says so when another beside it has the name, as BaseCamp does.
    func rename(_ node: LibraryNode, to name: String) {
        var renamed = false
        switch node {
        case .list(let id):
            edit("Rename List") { renamed = $0.renameCollection(id, to: name) }
        case .folder(let id):
            edit("Rename List Folder") { renamed = $0.renameFolder(id, to: name) }
        default:
            return
        }
        if !renamed, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != self.name(of: node) {
            errorMessage = if case .folder = node {
                "This folder name has already been used. Please enter a unique folder name."
            } else {
                "This list name has already been used. Please enter a unique list name."
            }
        }
    }

    /// Moves a list or folder into a folder, or to the top of My Collection (nil).
    func move(_ node: LibraryNode, to folder: UUID?) {
        var moved = false
        switch node {
        case .list(let id):
            guard library.collections.first(where: { $0.id == id })?.folderID != folder else { return }
            edit("Move List") { moved = $0.moveList(id, to: folder) }
        case .folder(let id):
            guard library.folders.first(where: { $0.id == id })?.parentID != folder else { return }
            if let folder, library.folderTree(id).contains(folder) {
                errorMessage = "Cannot move \(name(of: node)) to itself."
                return
            }
            edit("Move List Folder") { moved = $0.moveFolder(id, to: folder) }
        default:
            return
        }
        if !moved {
            let place = folder.map { name(of: .folder($0)) } ?? "My Collection"
            errorMessage = "\(place) already has a \(node.isFolder ? "folder" : "list") named \(name(of: node))."
        }
    }

    /// Adds library items to a list. Says so when they were all in it already.
    func add(_ items: [LibraryItem], toList id: UUID) {
        let wanted = items.filter { !isOnDevice($0) }.map(CollectionItem.init)
        guard !wanted.isEmpty else { return }
        var already: [CollectionItem] = []
        edit("Add to List") { already = $0.add(wanted, toList: id) }
        if already.count == wanted.count, let item = items.first {
            errorMessage = "\(name(of: .list(id))) already contains \(wanted.count == 1 ? self.name(of: item) : "these items")."
        }
    }

    /// Adds the selected items to a list.
    func addSelection(toList id: UUID) {
        add(Array(selectedItems), toList: id)
    }

    /// Adds the selected items to a new list in the selected folder, then asks for its name.
    func addSelectionToNewList() {
        let items = selectedItems.filter { !isOnDevice($0) }.map(CollectionItem.init)
        let folder = folderForNewNodes
        var id: UUID?
        edit("New List") { id = $0.createList(in: folder, items: items) }
        if let id {
            renaming = .list(id)
        }
    }

    /// Takes the selected items out of the selected list. They stay in My Collection.
    func removeSelectionFromList() {
        guard let id = selectedListID else { return }
        let items = Set(selectedItems.map(CollectionItem.init))
        edit("Remove from List") { $0.remove(items, fromList: id) }
        selectedItems = []
    }

    /// Asks before removing a list or folder (see `confirmRemoval`).
    func requestRemoval(_ node: LibraryNode) {
        switch node {
        case .list, .folder: pendingNodeRemoval = node
        default: break
        }
    }

    /// The items a list or folder holds that are in no other list: deleting them leaves them nowhere but My Collection.
    func uniqueItems(of node: LibraryNode) -> Int {
        switch node {
        case .list(let id): library.uniqueItems(ofList: id).count
        case .folder(let id): library.uniqueItems(ofFolder: id).count
        default: 0
        }
    }

    /// Removes a list or folder. Its items stay in My Collection, unless `deletingUniqueItems`.
    func remove(_ node: LibraryNode, deletingUniqueItems: Bool) {
        switch node {
        case .list(let id):
            edit(deletingUniqueItems ? "Delete List and Contents" : "Remove List") { $0.removeList(id, deletingUniqueItems: deletingUniqueItems) }
        case .folder(let id):
            edit(deletingUniqueItems ? "Delete Folder and Contents" : "Remove Folder") {
                $0.removeFolder(id, deletingUniqueItems: deletingUniqueItems)
            }
        default:
            return
        }
        if !libraryHas(selectedNode) {
            selectedNode = .myCollection
        }
    }

    /// Copies a list beside it, with copies of its items or the same items.
    func duplicateList(_ id: UUID, copyingItems: Bool) {
        var copy: UUID?
        edit("Duplicate List") { copy = $0.duplicateList(id, copyingItems: copyingItems) }
        if let copy {
            selectedNode = .list(copy)
        }
    }

    private func libraryHas(_ node: LibraryNode) -> Bool {
        switch node {
        case .list(let id): library.collections.contains { $0.id == id }
        case .folder(let id): library.folders.contains { $0.id == id }
        default: true
        }
    }

    /// New items go where BaseCamp puts them: into the selected list, as part of the step that made them; with a
    /// list folder selected, the user picks a list in it (`pendingListChoice`). They are in My Collection anyway.
    private func placeNewItems(_ items: [LibraryItem]) {
        let wanted = items.map(CollectionItem.init)
        guard !wanted.isEmpty else { return }
        switch selectedNode {
        case .list(let id):
            if history.amend({ $0.add(wanted, toList: id) }) {
                revision += 1
                save()
            }
        case .folder(let id):
            pendingListChoice = ListChoice(items: wanted, folder: id)
        default:
            break
        }
    }

    /// Puts new items into a list of the folder, or a new list named `newListName` in it.
    func placeItems(_ choice: ListChoice, inList list: UUID?, newListName: String) {
        edit("Add to List") { library in
            if let list {
                library.add(choice.items, toList: list)
            } else {
                let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                library.createList(in: choice.folder, name: name.isEmpty ? "New List" : name, items: choice.items)
            }
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

    /// Keeps one point every `seconds` in the selected track (see `Track.thinned(everySeconds:)`). Routes have no
    /// times or readings to filter by, so they are left as they are.
    func thinSelectedTrack(everySeconds seconds: TimeInterval) {
        editSelection("Filter Points", track: { $0.thinned(everySeconds: seconds) }, route: { $0 })
    }

    /// Keeps one point every `metres` along the selected track (see `Track.thinned(everyMetres:)`).
    func thinSelectedTrack(everyMetres metres: Double) {
        editSelection("Filter Points", track: { $0.thinned(everyMetres: metres) }, route: { $0 })
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

    /// Starts a new route with one stop, with the routing profile its legs are calculated with, and selects it.
    @discardableResult
    func startRoute(at coordinate: Coordinate, profileID: UUID?) -> UUID {
        let number = library.routes.count + 1
        let names = Set(library.routes.map(\.name))
        let name = (number...).lazy.map { "Route \($0)" }.first { !names.contains($0) } ?? "Route"
        let route = Route(name: name, stops: [RouteStop(coordinate: coordinate)], profileID: profileID)
        addRoute(route)
        return route.id
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
            library.routes[routeIndex].updateStop(at: index) { stop in
                stop.name = name.isEmpty ? nil : name
                stop.hasMapName = false
            }
        }
    }

    /// One stop's name read from the map, for the place the stop was at.
    struct MapStopName {
        let route: UUID
        let stop: UUID
        let coordinate: Coordinate
        let name: String
    }

    /// Gives stops without a name the names read from the map (see `StopNamer`), as part of the step that added or
    /// moved them: undo takes back both. A stop that moved or was named in the meantime is left alone.
    func applyMapStopNames(_ names: [MapStopName]) {
        let changed = history.amend { library in
            for found in names {
                guard let routeIndex = library.routes.firstIndex(where: { $0.id == found.route }),
                      let index = library.routes[routeIndex].stops.firstIndex(where: { $0.id == found.stop }),
                      library.routes[routeIndex].stops[index].coordinate == found.coordinate,
                      library.routes[routeIndex].stops[index].needsName else { continue }
                library.routes[routeIndex].updateStop(at: index) { stop in
                    stop.name = found.name
                    stop.hasMapName = true
                }
            }
        }
        if changed {
            revision += 1
            save()
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

    /// Keeps legs of a route straight (true), never sent to the router, as for a path missing from its data; or
    /// hands them back to the router (false), which recalculates them with the route's profile.
    func setRouteLegsStraight(_ route: UUID, legs: [Int], straight: Bool) {
        edit(straight ? "Keep Leg Straight" : "Route Leg") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == route }) else { return }
            for leg in legs {
                library.routes[routeIndex].setLegStraight(at: leg, straight)
            }
        }
    }

    /// Sets the routing profile a route's changed legs are recalculated with. Nothing is recalculated by this.
    func setRouteProfile(_ route: UUID, profileID: UUID?) {
        edit("Change Routing") { library in
            guard let routeIndex = library.routes.firstIndex(where: { $0.id == route }) else { return }
            library.routes[routeIndex].profileID = profileID
        }
    }

    /// Marks every leg of the route to be calculated again (see `Route.markAllLegsForRecalculation`). A route without
    /// a profile, such as an imported one, takes `fallbackProfile`, as BaseCamp recalculates with the current
    /// activity. Returns false when the route has no legs, so nothing would be calculated.
    @discardableResult
    func markRouteForRecalculation(_ id: UUID, fallbackProfile: UUID) -> Bool {
        var marked = false
        edit("Recalculate Route") { library in
            guard let index = library.routes.firstIndex(where: { $0.id == id }), !library.routes[index].legs.isEmpty else { return }
            if library.routes[index].profileID == nil {
                library.routes[index].profileID = fallbackProfile
            }
            marked = library.routes[index].markAllLegsForRecalculation()
        }
        return marked
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
            placeNewItems([.track(copy.id)])
            selection = .track(copy.id)
        case .route(let id)?:
            guard let route = route(id) else { return }
            var copy = route
            copy.id = UUID()
            copy.name = route.name + " copy"
            edit("Duplicate") { $0.routes.append(copy) }
            placeNewItems([.route(copy.id)])
            selection = .route(copy.id)
        default:
            break
        }
    }

    /// Cuts the selected track in two at the point under the elevation profile's cursor.
    /// Returns false when there is no cursor position or the selection is not a track.
    @discardableResult
    func splitSelectedTrackAtCursor() -> Bool {
        guard case .track(let id)? = selection, let cursor = profileCursor,
              let track = track(id), let pieces = track.split(atDistance: cursor) else { return false }
        edit("Split Track") { $0.splitTrack(id, into: pieces) }
        selection = .track(pieces.0.id)
        return true
    }

    /// Deletes the points of the selected track that lie in the picked stretch of its profile, in one undo step.
    func deleteProfileRange() {
        guard case .track(let id)? = selection, let range = profileRange else { return }
        edit("Delete Points") { library in
            guard let index = library.tracks.firstIndex(where: { $0.id == id }),
                  let trimmed = library.tracks[index].removingPoints(distanceIn: range) else { return }
            library.tracks[index] = trimmed
        }
        profileRange = nil
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
