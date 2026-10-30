import BaseCampCore
import BaseCampMTP
import Foundation

// Read-only check of a connected Garmin Edge over MTP.
// Lists each storage and the folders Edge devices use. It writes nothing to the device.

// `listAll` prints every entry. Otherwise only a count is printed, for large folders.
let paths: [(path: [String], listAll: Bool)] = [
    ([], true),
    (["Garmin"], false),
    (["Garmin", "NewFiles"], true),
    (["Garmin", "Courses"], true),
    (["Garmin", "Activities"], false),
    (["Garmin", "CustomMaps"], true),
]

// `EdgeProbe watch SECONDS` prints Garmin USB devices as they are plugged in and out, for SECONDS. It opens nothing.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "watch", let seconds = Double(CommandLine.arguments[2]) {
    let watcher = GarminUSBWatcher { event in
        switch event {
        case .arrived(let usb, let present):
            print(String(format: "%@ bus %d address %d, %04x:%04x", present ? "Present" : "Arrived", usb.bus, usb.address, usb.vendorID, usb.productID))
        case .left(let usb):
            print(String(format: "Left bus %d address %d, %04x:%04x", usb.bus, usb.address, usb.vendorID, usb.productID))
        }
    }
    guard let watcher else {
        print("USB hotplug is not available")
        exit(1)
    }
    Thread.sleep(forTimeInterval: seconds)
    watcher.stop()
    exit(0)
}

// `EdgeProbe load FOLDER` reads the device as the app does when it connects: its storages, then every file in
// Garmin/Courses, Garmin/Activities and Garmin/NewFiles, one piece of work each, into FOLDER, with the time taken.
// It reads from the device and writes only the local copies.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "load" {
    let folder = URL(fileURLWithPath: CommandLine.arguments[2])
    let device = MTPDevice { try MTPConnection.openFirstGarmin() }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let start = Date()
            let status = try await device.status()
            print("Opened \(status.identity.product) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            let listed = try await device.perform { link, storage in
                try [["Garmin", "Courses"], ["Garmin", "Activities"], ["Garmin", "NewFiles"]].map { path in
                    (path, try link.entries(in: path, storageID: storage.id).filter { !$0.isFolder })
                }
            }
            print("Listed in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            var bytes: UInt64 = 0
            var count = 0
            for (path, files) in listed {
                let local = folder.appendingPathComponent(path.joined(separator: "-"))
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                for file in files {
                    try await device.perform { link, _ in
                        try link.download(entryID: file.id, to: local.appendingPathComponent(file.name))
                    }
                    bytes += file.size
                    count += 1
                }
            }
            let seconds = Date().timeIntervalSince(start)
            print("Read \(count) files, \(bytes) bytes, in \(String(format: "%.2f", seconds)) s")
        } catch {
            print("Could not load: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// `EdgeProbe maps` lists the .img maps in Garmin/ with their size and kind. Read-only.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "maps" {
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        let files = try device.entries(in: ["Garmin"], storageID: storageID).filter { !$0.isFolder }
        let names = Set(files.map { $0.name.lowercased() })
        for file in files.filter({ $0.name.lowercased().hasSuffix(".img") }).sorted(by: { $0.name < $1.name }) {
            let kind = DeviceMapKind.classify(name: file.name, siblings: names)
            print("\(file.name)  \(file.size) bytes  \(kind)")
        }
    } catch {
        print("Could not list maps: \(error)")
        exit(1)
    }
    exit(0)
}

// `EdgeProbe delete-custom NAME` deletes one custom map from Garmin/, matched by exact name.
// Licensed and built-in maps are refused.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "delete-custom" {
    let name = CommandLine.arguments[2]
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        let files = try device.entries(in: ["Garmin"], storageID: storageID).filter { !$0.isFolder }
        let names = Set(files.map { $0.name.lowercased() })
        guard let target = files.first(where: { $0.name == name }) else {
            print("Not found: \(name)")
            exit(1)
        }
        let kind = DeviceMapKind.classify(name: target.name, siblings: names)
        guard kind.canDelete else {
            print("Refused: \(name) is \(kind)")
            exit(1)
        }
        try device.delete(entryID: target.id, named: target.name, in: ["Garmin"], storageID: storageID)
        print("Deleted \(name)")
    } catch {
        print("Could not delete: \(error)")
        exit(1)
    }
    exit(0)
}

// `EdgeProbe delete-course NAME` deletes one course from Garmin/Courses, matched by exact file name.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "delete-course" {
    let name = CommandLine.arguments[2]
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        let files = try device.entries(in: ["Garmin", "Courses"], storageID: storageID).filter { !$0.isFolder }
        guard let course = files.first(where: { $0.name == name }) else {
            print("Not found: \(name)")
            exit(1)
        }
        try device.delete(entryID: course.id, named: course.name, in: ["Garmin", "Courses"], storageID: storageID)
        print("Deleted \(name)")
    } catch {
        print("Could not delete: \(error)")
        exit(1)
    }
    exit(0)
}

// `EdgeProbe list PATH` lists one folder, such as Garmin/Locations. Read-only.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "list" {
    let path = CommandLine.arguments[2].split(separator: "/").map(String.init)
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        for entry in try device.entries(in: path, storageID: storageID).sorted(by: { $0.name < $1.name }) {
            print("\(entry.isFolder ? "dir " : "file") \(entry.name) (\(entry.size) bytes)")
        }
    } catch {
        print("Could not list: \(error)")
        exit(1)
    }
    exit(0)
}

// `EdgeProbe fetch PATH/NAME OUTPUT` copies one file, such as GarminDevice.xml or Garmin/Locations/Locations.fit,
// to OUTPUT. It reads from the device and writes only the local copy.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "fetch" {
    var path = CommandLine.arguments[2].split(separator: "/").map(String.init)
    let name = path.removeLast()
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        guard let file = try device.entries(in: path, storageID: storageID).first(where: { !$0.isFolder && $0.name == name }) else {
            print("Not found: \(CommandLine.arguments[2])")
            exit(1)
        }
        try device.download(entryID: file.id, to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print("Copied \(name) (\(file.size) bytes) to \(CommandLine.arguments[3])")
    } catch {
        print("Could not fetch: \(error)")
        exit(1)
    }
    exit(0)
}

// `EdgeProbe fetch-smallest OUTPUT.fit` copies the smallest activity from Garmin/Activities to OUTPUT.
// It reads from the device and writes only the local copy.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "fetch-smallest" {
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        let files = try device.entries(in: ["Garmin", "Activities"], storageID: storageID)
            .filter { !$0.isFolder }
            .sorted { $0.size < $1.size }
        guard let smallest = files.first else {
            print("No activities found")
            exit(1)
        }
        try device.download(entryID: smallest.id, to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Copied \(smallest.name) (\(smallest.size) bytes) to \(CommandLine.arguments[2])")
    } catch {
        print("Could not fetch: \(error)")
        exit(1)
    }
    exit(0)
}

// `EdgeProbe fetch-course NAME OUTPUT.fit` copies one course from Garmin/Courses, matched by exact name, to OUTPUT.
// It reads from the device and writes only the local copy.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "fetch-course" {
    let name = CommandLine.arguments[2]
    do {
        let device = try MTPConnection.openFirstGarmin()
        let storageID = try device.storages().first?.id ?? 0
        let files = try device.entries(in: ["Garmin", "Courses"], storageID: storageID).filter { !$0.isFolder }
        guard let course = files.first(where: { $0.name == name }) else {
            print("Not found: \(name)")
            exit(1)
        }
        try device.download(entryID: course.id, to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print("Copied \(course.name) (\(course.size) bytes) to \(CommandLine.arguments[3])")
    } catch {
        print("Could not fetch: \(error)")
        exit(1)
    }
    exit(0)
}

do {
    let device = try MTPConnection.openFirstGarmin()
    for storage in try device.storages() {
        print("Storage \(storage.id): \(storage.name), \(storage.freeBytes) of \(storage.capacityBytes) bytes free")
        for (path, listAll) in paths {
            let label = "/" + path.joined(separator: "/")
            do {
                let entries = try device.entries(in: path, storageID: storage.id)
                let folders = entries.filter(\.isFolder).count
                print("  \(label): \(entries.count) entries (\(folders) folders, \(entries.count - folders) files)")
                guard listAll else { continue }
                for entry in entries.sorted(by: { $0.name < $1.name }) {
                    print("    \(entry.isFolder ? "dir " : "file") \(entry.name) (\(entry.size) bytes)")
                }
            } catch {
                print("  \(label): \(error)")
            }
        }
    }
} catch {
    print("Could not open the device: \(error)")
    exit(1)
}
