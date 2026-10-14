import Foundation

/// The average and the maximum of a sensor reading over a track.
public struct SeriesSummary: Equatable, Sendable {
    public var average: Double
    public var maximum: Double

    public init(average: Double, maximum: Double) {
        self.average = average
        self.maximum = maximum
    }
}

/// A value a profile can plot against distance: the height, or one of the sensor readings.
public enum ProfileSeries: CaseIterable, Sendable {
    case elevation
    case heartRate
    case cadence
    case power
    case temperature
}

/// Distance, time, speed and climb of a track or a route. Values that need timestamps or elevations
/// are nil when the data is missing.
public struct ActivityStatistics: Equatable, Sendable {
    public var distanceMeters: Double
    public var pointCount: Int
    /// Time from the first to the last timestamp.
    public var totalTime: TimeInterval?
    /// Time spent at or above `movingSpeed`.
    public var movingTime: TimeInterval?
    /// Distance divided by moving time, in metres per second.
    public var averageSpeed: Double?
    /// The fastest step between two timestamps that is not a GPS error. In metres per second.
    public var maximumSpeed: Double?
    public var ascentMeters: Double?
    public var descentMeters: Double?
    public var minimumElevation: Double?
    public var maximumElevation: Double?
    /// Sensor readings, where the track has them.
    public var heartRate: SeriesSummary?
    public var cadence: SeriesSummary?
    public var power: SeriesSummary?
    public var temperature: SeriesSummary?

    /// Below this speed (metres per second) the rider counts as stopped.
    public static let movingSpeed = 0.5
    /// Faster than this (metres per second) is treated as a GPS error.
    public static let maximumPlausibleSpeed = 40.0
    /// Elevation changes smaller than this (metres) are treated as noise when adding up the climb.
    public static let elevationNoise = 3.0

    /// One point of a track or route, as far as the statistics need it.
    struct Sample {
        var coordinate: Coordinate
        var elevation: Double?
        var time: Date?
        var heartRate: Double?
        var cadence: Double?
        var power: Double?
        var temperature: Double?
    }

    /// Builds the statistics from segments of samples. Each segment is a run of points without a gap.
    init(segments: [[Sample]]) {
        var distance = 0.0
        var count = 0
        var times: [Date] = []
        var moving: TimeInterval = 0
        var movingDistance = 0.0
        var fastest: Double?
        var ascent = 0.0
        var descent = 0.0
        var elevations: [Double] = []
        var heartRates: [Double] = []
        var cadences: [Double] = []
        var powers: [Double] = []
        var temperatures: [Double] = []

        for segment in segments {
            count += segment.count
            times += segment.compactMap(\.time)
            elevations += segment.compactMap(\.elevation)
            heartRates += segment.compactMap(\.heartRate)
            cadences += segment.compactMap(\.cadence)
            powers += segment.compactMap(\.power)
            temperatures += segment.compactMap(\.temperature)
            if let profile = Self.climb(segment.compactMap(\.elevation), threshold: Self.elevationNoise) {
                ascent += profile.ascent
                descent += profile.descent
            }

            for (a, b) in zip(segment, segment.dropFirst()) {
                let step = Geodesy.distance(from: a.coordinate, to: b.coordinate)
                distance += step
                guard let start = a.time, let end = b.time else { continue }
                let seconds = end.timeIntervalSince(start)
                guard seconds > 0 else { continue }
                let speed = step / seconds
                if speed >= Self.movingSpeed {
                    moving += seconds
                    movingDistance += step
                }
                if speed <= Self.maximumPlausibleSpeed {
                    fastest = max(fastest ?? 0, speed)
                }
            }
        }

        self.distanceMeters = distance
        self.pointCount = count
        if let first = times.min(), let last = times.max(), first < last {
            self.totalTime = last.timeIntervalSince(first)
        }
        if moving > 0 {
            self.movingTime = moving
            self.averageSpeed = movingDistance / moving
        }
        self.maximumSpeed = fastest
        if !elevations.isEmpty {
            self.ascentMeters = ascent
            self.descentMeters = descent
            self.minimumElevation = elevations.min()
            self.maximumElevation = elevations.max()
        }
        self.heartRate = Self.summary(heartRates)
        self.cadence = Self.summary(cadences)
        self.power = Self.summary(powers)
        self.temperature = Self.summary(temperatures)
    }

    /// The series this track or route has data for, in the order of `ProfileSeries`.
    public var availableSeries: [ProfileSeries] {
        var result: [ProfileSeries] = []
        if minimumElevation != nil { result.append(.elevation) }
        if heartRate != nil { result.append(.heartRate) }
        if cadence != nil { result.append(.cadence) }
        if power != nil { result.append(.power) }
        if temperature != nil { result.append(.temperature) }
        return result
    }

    /// The average and maximum of the readings, or nil when there are none.
    private static func summary(_ values: [Double]) -> SeriesSummary? {
        guard !values.isEmpty else { return nil }
        return SeriesSummary(average: values.reduce(0, +) / Double(values.count), maximum: values.max() ?? 0)
    }

    /// Adds up the climb and descent of a series of elevations. A rise or fall only counts once it is
    /// at least `threshold` metres from the last turning point, so GPS jitter does not add height.
    public static func climb(_ values: [Double], threshold: Double) -> (ascent: Double, descent: Double)? {
        guard let first = values.first else { return nil }
        var reference = first
        var extreme = first
        var rising: Bool?
        var ascent = 0.0
        var descent = 0.0

        for value in values.dropFirst() {
            switch rising {
            case nil:
                if value - reference >= threshold {
                    rising = true
                    extreme = value
                } else if reference - value >= threshold {
                    rising = false
                    extreme = value
                }
            case true?:
                if value > extreme {
                    extreme = value
                } else if extreme - value >= threshold {
                    ascent += extreme - reference
                    reference = extreme
                    rising = false
                    extreme = value
                }
            case false?:
                if value < extreme {
                    extreme = value
                } else if value - extreme >= threshold {
                    descent += reference - extreme
                    reference = extreme
                    rising = true
                    extreme = value
                }
            }
        }
        switch rising {
        case true?: ascent += extreme - reference
        case false?: descent += reference - extreme
        case nil: break
        }
        return (ascent, descent)
    }
}

/// One point of an elevation profile: where along the track or route, how high, and where on the map.
public struct ElevationProfilePoint: Equatable, Sendable, Identifiable {
    public var id: Int
    public var distanceMeters: Double
    /// The height in metres, or the reading of the series the profile plots.
    public var value: Double
    public var coordinate: Coordinate
}

public extension Track {
    var statistics: ActivityStatistics {
        ActivityStatistics(segments: segments.map { segment in
            segment.map {
                ActivityStatistics.Sample(
                    coordinate: $0.coordinate, elevation: $0.elevation, time: $0.time,
                    heartRate: $0.heartRate, cadence: $0.cadence, power: $0.power, temperature: $0.temperature
                )
            }
        })
    }

    /// Distance along the track against elevation. Points without an elevation are left out of the profile.
    var elevationProfile: [ElevationProfilePoint] {
        profile(of: .elevation)
    }

    /// Distance along the track against one series. Points without a value for it are left out.
    func profile(of series: ProfileSeries) -> [ElevationProfilePoint] {
        makeProfile(of: segments.map { segment in segment.map { ($0.coordinate, Self.value(of: series, $0)) } })
    }

    private static func value(of series: ProfileSeries, _ point: TrackPoint) -> Double? {
        switch series {
        case .elevation: point.elevation
        case .heartRate: point.heartRate
        case .cadence: point.cadence
        case .power: point.power
        case .temperature: point.temperature
        }
    }
}

public extension Route {
    var statistics: ActivityStatistics {
        ActivityStatistics(segments: [points.map { ActivityStatistics.Sample(coordinate: $0.coordinate, elevation: $0.elevation, time: nil) }])
    }

    /// Distance along the route against one series. A route has only its elevation: other series are empty.
    func profile(of series: ProfileSeries) -> [ElevationProfilePoint] {
        series == .elevation ? elevationProfile : []
    }

    /// Distance along the route against elevation. Points without an elevation are left out of the profile.
    var elevationProfile: [ElevationProfilePoint] {
        makeProfile(of: [points.map { ($0.coordinate, $0.elevation) }])
    }
}

/// Builds a profile from segments of (coordinate, elevation) pairs. Distance is not counted across gaps.
private func makeProfile(of segments: [[(Coordinate, Double?)]]) -> [ElevationProfilePoint] {
    var result: [ElevationProfilePoint] = []
    var distance = 0.0
    for segment in segments {
        var previous: Coordinate?
        for (coordinate, elevation) in segment {
            if let previous {
                distance += Geodesy.distance(from: previous, to: coordinate)
            }
            previous = coordinate
            if let elevation {
                result.append(ElevationProfilePoint(
                    id: result.count,
                    distanceMeters: distance,
                    value: elevation,
                    coordinate: coordinate
                ))
            }
        }
    }
    return result
}
