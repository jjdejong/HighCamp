import BaseCampCore
import Foundation

/// What is on the device, shown next to the library as BaseCamp shows a device: its courses, its saved locations,
/// its activities and the waypoints, routes and tracks of its GPX files. Read-only: an item is copied to the library to change it.
struct DeviceContents: Equatable {
    /// The device's name, as the status bar shows it.
    var deviceName = ""
    var groups: [DeviceGroup] = []
    /// Files read so far and files to read, while reading.
    var progress: (done: Int, total: Int)?

    static func == (lhs: DeviceContents, rhs: DeviceContents) -> Bool {
        lhs.deviceName == rhs.deviceName && lhs.groups == rhs.groups
            && lhs.progress?.done == rhs.progress?.done && lhs.progress?.total == rhs.progress?.total
    }

    /// Every item of every group, for looking items up by id.
    var library: Library {
        var all = Library()
        for group in groups {
            all.waypoints += group.library.waypoints
            all.routes += group.library.routes
            all.tracks += group.library.tracks
        }
        return all
    }
}

/// A file on the device: its folder and name.
struct DeviceFileRef: Hashable, Identifiable {
    let kind: DeviceGroup.Kind
    let name: String

    var id: String { "\(kind.rawValue)/\(name)" }
}

/// One folder of the device and the items read from it.
struct DeviceGroup: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case courses, locations, activities, gpx

        /// The folder on the device.
        var folder: [String] {
            switch self {
            case .courses: ["Garmin", "Courses"]
            case .locations: ["Garmin", "Locations"]
            case .activities: ["Garmin", "Activities"]
            case .gpx: ["Garmin", "GPX"]
            }
        }

        var title: String {
            switch self {
            case .courses: "Courses"
            case .locations: "Saved Locations"
            case .activities: "Activities"
            case .gpx: "GPX Files"
            }
        }

        var fileExtension: String {
            self == .gpx ? "gpx" : "fit"
        }

        /// Drawn on the map until the user says otherwise. A device holds hundreds of activities, which would bury
        /// the map; a selected one is drawn anyway.
        var shownOnMapByDefault: Bool {
            self != .activities
        }

        /// Whether one item's file can be deleted without taking others: the Edge keeps every saved location in
        /// one file, so those are deleted on the Edge itself.
        var canDeleteFiles: Bool {
            self != .locations
        }
    }

    let kind: Kind
    var library = Library()
    /// The file on the device each item was read from. A GPX file can hold several items.
    var files: [LibraryItem: String] = [:]

    var id: String { kind.rawValue }

    /// Every item of the group, waypoints first.
    var items: [LibraryItem] {
        library.waypoints.map { .waypoint($0.id) } + library.routes.map { .route($0.id) } + library.tracks.map { .track($0.id) }
    }
}

enum DeviceFileReader {
    /// The items in one file from the device, with ids that stay the same each time the file is read.
    static func items(in data: Data, file name: String, kind: DeviceGroup.Kind) -> Library {
        let stem = (name as NSString).deletingPathExtension
        let key = "\(kind.rawValue)/\(name)"
        switch kind {
        case .courses, .activities:
            guard var track = try? FITActivity.read(data, name: stem), track.pointCount > 0 else { return Library() }
            track.id = UUID(stableFrom: key)
            if kind == .activities, let start = track.segments.first?.first?.time {
                track.name = start.formatted(date: .abbreviated, time: .shortened)
            }
            var library = Library()
            library.tracks = [track]
            return library
        case .locations:
            guard var waypoints = try? FITLocations.read(data) else { return Library() }
            // By name and place: the file's order changes when a location is added or deleted on the Edge.
            for index in waypoints.indices {
                let place = waypoints[index].coordinate
                waypoints[index].id = UUID(stableFrom: "\(key)/\(waypoints[index].name)/\(place.latitude),\(place.longitude)")
            }
            return Library(waypoints: waypoints)
        case .gpx:
            guard var library = try? GPX.read(data).library else { return Library() }
            for index in library.waypoints.indices {
                library.waypoints[index].id = UUID(stableFrom: "\(key)/waypoint/\(index)")
            }
            for index in library.routes.indices {
                library.routes[index].id = UUID(stableFrom: "\(key)/route/\(index)")
            }
            for index in library.tracks.indices {
                library.tracks[index].id = UUID(stableFrom: "\(key)/track/\(index)")
            }
            library.collections = []
            return library
        }
    }
}
