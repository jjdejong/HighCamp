import BaseCampMTP
import Foundation

// Usage: EdgeSend [--replace] FILE FOLDER
// Sends FILE into FOLDER on the Edge's internal storage, for example:
//   EdgeSend course.fit Garmin/Courses
// The upload is verified on the device before the command reports success. With --replace, a file of the same
// name is replaced, keeping a checked copy of the old or the new file on the device at every step.

var arguments = CommandLine.arguments
let replacing = arguments.count == 4 && arguments[1] == "--replace"
if replacing { arguments.remove(at: 1) }
guard arguments.count == 3 else {
    print("usage: EdgeSend [--replace] FILE FOLDER   (for example: EdgeSend course.fit Garmin/Courses)")
    exit(2)
}

let fileURL = URL(fileURLWithPath: arguments[1])
let folder = arguments[2].split(separator: "/").map(String.init)

do {
    let device = try MTPConnection.openFirstGarmin()
    guard let storage = try device.storages().first else {
        print("FAILED: the device reports no storage")
        exit(1)
    }
    if replacing {
        try MTPTransfers.replace(device, localFile: fileURL, in: folder, named: fileURL.lastPathComponent, storageID: storage.id)
    } else {
        try device.upload(localFile: fileURL, to: folder, as: fileURL.lastPathComponent, storageID: storage.id)
    }
    print("OK: \(fileURL.lastPathComponent) \(replacing ? "replaced and " : "")verified in /\(folder.joined(separator: "/")) on \(storage.name)")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
