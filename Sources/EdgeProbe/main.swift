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

// `EdgeProbe maps` lists the .img maps in Garmin/ with their size and kind. Read-only.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "maps" {
    do {
        let device = try MTPConnection.openFirstDevice()
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
        let device = try MTPConnection.openFirstDevice()
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

// `EdgeProbe fetch-smallest OUTPUT.fit` copies the smallest activity from Garmin/Activities to OUTPUT.
// It reads from the device and writes only the local copy.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "fetch-smallest" {
    do {
        let device = try MTPConnection.openFirstDevice()
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

do {
    let device = try MTPConnection.openFirstDevice()
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
