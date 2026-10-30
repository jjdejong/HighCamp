// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BaseCampClone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BaseCampCore", targets: ["BaseCampCore"]),
        .library(name: "BaseCampMTP", targets: ["BaseCampMTP"]),
        .executable(name: "BaseCampApp", targets: ["BaseCampApp"]),
        .executable(name: "EdgeProbe", targets: ["EdgeProbe"]),
        .executable(name: "EdgeSend", targets: ["EdgeSend"]),
    ],
    targets: [
        .target(name: "BaseCampCore"),

        // Garmin IMG map container, ported from QMapShack (GPL-3.0-or-later). See NOTICE.md.
        .target(name: "BaseCampIMG", dependencies: ["BaseCampCore"]),
        .testTarget(name: "BaseCampIMGTests", dependencies: ["BaseCampIMG"]),

        // libmtp, installed with `brew install libmtp`.
        .systemLibrary(
            name: "CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),
        // libusb, installed with libmtp, which uses it. Finds Garmin devices without opening any other.
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(name: "BaseCampMTP", dependencies: ["CLibMTP", "CLibUSB"]),
        .testTarget(name: "BaseCampMTPTests", dependencies: ["BaseCampMTP"]),

        // GDAL, installed with `brew install gdal`. Reads the elevation models (DEM) that QMapShack uses.
        .systemLibrary(
            name: "CGDAL",
            pkgConfig: "gdal",
            providers: [.brew(["gdal"])]
        ),
        .target(name: "BaseCampDEM", dependencies: ["BaseCampCore", "CGDAL"]),
        .testTarget(name: "BaseCampDEMTests", dependencies: ["BaseCampDEM", "BaseCampCore", "CGDAL"]),

        .executableTarget(name: "BaseCampApp", dependencies: ["BaseCampCore", "BaseCampMTP", "BaseCampIMG", "BaseCampDEM"]),
        .executableTarget(name: "EdgeProbe", dependencies: ["BaseCampCore", "BaseCampMTP"]),
        .executableTarget(name: "EdgeSend", dependencies: ["BaseCampMTP"]),

        .testTarget(name: "BaseCampCoreTests", dependencies: ["BaseCampCore"]),
    ]
)
