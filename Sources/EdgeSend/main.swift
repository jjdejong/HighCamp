import BaseCampMTP
import Foundation

// Usage: EdgeSend FILE FOLDER
// Sends FILE into FOLDER on the Edge's internal storage, for example:
//   EdgeSend course.fit Garmin/Courses
// The upload is verified on the device before the command reports success.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: EdgeSend FILE FOLDER   (for example: EdgeSend course.fit Garmin/Courses)")
    exit(2)
}

let fileURL = URL(fileURLWithPath: arguments[1])
let folder = arguments[2].split(separator: "/").map(String.init)

do {
    let device = try MTPConnection.openFirstDevice()
    guard let storage = try device.storages().first else {
        print("FAILED: the device reports no storage")
        exit(1)
    }
    try device.upload(
        localFile: fileURL,
        to: folder,
        as: fileURL.lastPathComponent,
        storageID: storage.id
    )
    print("OK: \(fileURL.lastPathComponent) verified in /\(folder.joined(separator: "/")) on \(storage.name)")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
