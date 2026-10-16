import Foundation

public enum RouteError: Error, Equatable {
    /// The router found no route with these points and avoidance areas.
    case noRoute(String)
    /// The router has no map data for this area, so it cannot route here at all.
    case missingSegments(String)
    /// The router could not be reached or returned an error.
    case server(Int, String)
    case malformedResponse
}

/// An area the route must not pass through, as a circle.
public struct NoGo: Equatable, Sendable {
    public let center: Coordinate
    public let radiusMeters: Double

    public init(center: Coordinate, radiusMeters: Double) {
        self.center = center
        self.radiusMeters = radiusMeters
    }
}

/// A calculated route: its points with heights, and its totals.
public struct RouteGeometry: Equatable, Sendable {
    public var points: [CoursePoint]
    public var lengthMeters: Double
    public var ascentMeters: Double
    public var durationSeconds: Double?

    public init(points: [CoursePoint], lengthMeters: Double, ascentMeters: Double, durationSeconds: Double? = nil) {
        self.points = points
        self.lengthMeters = lengthMeters
        self.ascentMeters = ascentMeters
        self.durationSeconds = durationSeconds
    }
}

/// Anything that can calculate a route through points while avoiding circles.
public protocol RouteSource: Sendable {
    func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry
}

/// Talks to a BRouter server, either the local one or brouter.de. Same API as QMapShack uses.
public struct BRouterClient: RouteSource {
    public typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: Data)

    public let baseURL: URL
    public let profile: String
    private let fetch: Fetch

    public init(baseURL: URL, profile: String, fetch: @escaping Fetch = BRouterClient.urlSessionFetch) {
        self.baseURL = baseURL
        self.profile = profile
        self.fetch = fetch
    }

    public func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
        let url = Self.requestURL(baseURL: baseURL, profile: profile, via: points, nogos: nogos)
        let (status, body) = try await fetch(url)
        guard status == 200 else {
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("datafile") && text.contains("not found") {
                throw RouteError.missingSegments(text)
            }
            if status == 400 {
                throw RouteError.noRoute(text)
            }
            throw RouteError.server(status, text)
        }
        return try Self.parse(body)
    }

    /// True when a server answers at this address. Any HTTP reply counts, even an error reply.
    public func isReachable() async -> Bool {
        do {
            _ = try await fetch(baseURL.appendingPathComponent("brouter"))
            return true
        } catch {
            return false
        }
    }

    public static func requestURL(baseURL: URL, profile: String, via points: [Coordinate], nogos: [NoGo]) -> URL {
        let endpoint = baseURL.appendingPathComponent("brouter")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "lonlats", value: points.map { lonLat($0) }.joined(separator: "|")),
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "alternativeidx", value: "0"),
            URLQueryItem(name: "format", value: "geojson"),
        ]
        if !nogos.isEmpty {
            let areas = nogos.map { area in
                "\(lonLat(area.center)),\(String(format: "%.0f", area.radiusMeters))"
            }
            items.append(URLQueryItem(name: "nogos", value: areas.joined(separator: "|")))
        }
        components.queryItems = items
        return components.url!
    }

    /// Reads the route from BRouter's GeoJSON. Each point carries its height as the third coordinate.
    public static func parse(_ data: Data) throws -> RouteGeometry {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feature = (json["features"] as? [[String: Any]])?.first,
              let geometry = feature["geometry"] as? [String: Any],
              let coordinates = geometry["coordinates"] as? [[Double]],
              let properties = feature["properties"] as? [String: Any] else {
            throw RouteError.malformedResponse
        }

        var points = coordinates.compactMap { values -> CoursePoint? in
            guard values.count >= 2 else { return nil }
            return CoursePoint(
                coordinate: Coordinate(latitude: values[1], longitude: values[0]),
                elevation: values.count >= 3 ? values[2] : nil
            )
        }
        // Both stops nearest to the same point of a way: BRouter gives that one point, a line of no length.
        if points.count == 1 {
            points.append(points[0])
        }
        guard points.count >= 2 else {
            throw RouteError.malformedResponse
        }

        func number(_ key: String) -> Double? {
            (properties[key] as? String).flatMap(Double.init)
        }
        let length = number("track-length") ?? zip(points, points.dropFirst()).reduce(0) {
            $0 + Geodesy.distance(from: $1.0.coordinate, to: $1.1.coordinate)
        }
        return RouteGeometry(
            points: points,
            lengthMeters: length,
            ascentMeters: number("filtered ascend") ?? 0,
            durationSeconds: number("total-time")
        )
    }

    /// The default transport: a plain HTTPS or HTTP GET.
    public static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    private static func lonLat(_ coordinate: Coordinate) -> String {
        String(format: "%.6f,%.6f", coordinate.longitude, coordinate.latitude)
    }
}
