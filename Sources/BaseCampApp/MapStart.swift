import CoreLocation
import MapKit

/// The map's last view, kept between launches, so the map opens where it was left, as BaseCamp's does.
enum SavedMapRegion {
    private static let key = "map.lastRegion"

    static func load() -> MKCoordinateRegion? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 4,
              values[2] > 0, values[3] > 0 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: values[0], longitude: values[1]),
            span: MKCoordinateSpan(latitudeDelta: values[2], longitudeDelta: values[3])
        )
    }

    static func save(_ region: MKCoordinateRegion) {
        UserDefaults.standard.set(
            [region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta],
            forKey: key
        )
    }
}

/// Finds the Mac's position once, through Location Services. macOS asks the user the first time.
@MainActor
final class LocationFinder: NSObject, CLLocationManagerDelegate {
    enum Problem: Error {
        case notAllowed
        case unavailable(String)

        var message: String {
            switch self {
            case .notAllowed:
                "Location Services are off for BaseCamp Clone. Turn them on in System Settings > Privacy & Security > Location Services."
            case .unavailable(let detail):
                "Your location could not be found. \(detail)"
            }
        }
    }

    private let manager = CLLocationManager()
    private var completion: ((Result<CLLocationCoordinate2D, Problem>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func locate(_ completion: @escaping (Result<CLLocationCoordinate2D, Problem>) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.failure(.notAllowed))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Problem>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard completion != nil else { return }
            switch status {
            case .notDetermined:
                break
            case .denied, .restricted:
                finish(.failure(.notAllowed))
            default:
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in finish(.success(location.coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            finish(.failure(denied ? .notAllowed : .unavailable(error.localizedDescription)))
        }
    }
}
