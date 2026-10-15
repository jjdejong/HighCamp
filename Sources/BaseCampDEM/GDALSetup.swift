import CGDAL
import Foundation

/// Starts GDAL once. In the packaged app, GDAL's and PROJ's data files are in the app's Resources (`gdal`, `proj`),
/// not where Homebrew put them on the Mac the app was built on, so GDAL is pointed at them first.
enum GDALSetup {
    static let started: Void = {
        if let resources = Bundle.main.resourceURL {
            let gdal = resources.appendingPathComponent("gdal")
            let proj = resources.appendingPathComponent("proj")
            if FileManager.default.fileExists(atPath: gdal.appendingPathComponent("gdalvrt.xsd").path) {
                CPLSetConfigOption("GDAL_DATA", gdal.path)
            }
            if FileManager.default.fileExists(atPath: proj.appendingPathComponent("proj.db").path) {
                proj.path.withCString { path in
                    var paths: [UnsafePointer<CChar>?] = [path, nil]
                    OSRSetPROJSearchPaths(&paths)
                }
            }
        }
        GDALAllRegister()
    }()
}
