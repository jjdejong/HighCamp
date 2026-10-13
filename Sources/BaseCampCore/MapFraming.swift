import Foundation

/// The area a map view shows when it is fitted to a set of coordinates.
public enum MapFraming {
    /// The smallest width and height, in metres, of a fitted area. Without it a single point zooms to the maximum.
    public static let minimumSpanMetres = 1_000.0

    /// The latitude limit of Web Mercator, which map views project with.
    static let mercatorLatitudeLimit = 85.05

    /// Keeps a latitude within the range Web Mercator can show, ±85.05.
    public static func clampLatitude(_ latitude: Double) -> Double {
        min(max(latitude, -mercatorLatitudeLimit), mercatorLatitudeLimit)
    }

    /// Keeps a longitude within ±180. A view that crosses the 180° meridian is cut at it, not wrapped.
    public static func clampLongitude(_ longitude: Double) -> Double {
        min(max(longitude, -180), 180)
    }

    /// The south-west and north-east corners of the area to show, or nil with no coordinates.
    /// The area is the coordinates' extent, grown about its centre until each side is at least `minimumSpanMetres`.
    public static func area(
        enclosing coordinates: [Coordinate],
        minimumSpanMetres: Double = MapFraming.minimumSpanMetres
    ) -> (southWest: Coordinate, northEast: Coordinate)? {
        guard let first = coordinates.first else { return nil }
        var south = first.latitude, north = first.latitude
        var west = first.longitude, east = first.longitude
        for coordinate in coordinates.dropFirst() {
            south = min(south, coordinate.latitude)
            north = max(north, coordinate.latitude)
            west = min(west, coordinate.longitude)
            east = max(east, coordinate.longitude)
        }

        let metresPerDegreeLatitude = Geodesy.earthRadiusMeters * .pi / 180
        let height = max(north - south, minimumSpanMetres / metresPerDegreeLatitude)
        // The centre stays far enough from the poles that the whole height is on the map.
        let centreLatitude = min(
            max((south + north) / 2, -mercatorLatitudeLimit + height / 2),
            mercatorLatitudeLimit - height / 2
        )
        let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(centreLatitude * .pi / 180)
        let centreLongitude = (west + east) / 2
        // Near the poles a metre spans many degrees of longitude, so the width stops at the whole globe.
        let width = min(360, max(east - west, minimumSpanMetres / metresPerDegreeLongitude))

        return (
            Coordinate(latitude: centreLatitude - height / 2, longitude: centreLongitude - width / 2),
            Coordinate(latitude: centreLatitude + height / 2, longitude: centreLongitude + width / 2)
        )
    }
}
