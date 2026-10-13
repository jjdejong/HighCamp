import Foundation

/// A stretch of route that climbs more steeply than allowed.
public struct SteepSection: Equatable, Sendable {
    /// Distance along the route where the section starts, in metres.
    public let startMeters: Double
    public let endMeters: Double
    /// The steepest smoothed grade within the section, in percent.
    public let maxGradePercent: Double
    /// A point in the middle of the section, used to route around it.
    public let center: Coordinate

    public var lengthMeters: Double {
        endMeters - startMeters
    }
}

public enum GradeAnalysis {
    /// Grades are measured over this much route, so single noisy height samples do not count.
    public static let defaultWindowMeters = 40.0

    /// Road and trail grades above this are height errors (bridges, tunnels, cliff edges in the terrain
    /// model), not climbs. They are ignored rather than sent to the router as steep sections.
    public static let implausibleGradePercent = 40.0

    /// Climbs steeper than `maxGradePercent`, measured over `windowMeters` of route.
    /// Points without a height are ignored, so the result is empty when no point has one.
    public static func steepSections(
        in points: [CoursePoint],
        maxGradePercent: Double,
        windowMeters: Double = defaultWindowMeters
    ) -> [SteepSection] {
        let distances = cumulativeDistances(points)
        let grades = uphillGrades(points, distances: distances, windowMeters: windowMeters)
        guard !grades.isEmpty else { return [] }

        // Group consecutive steep points into runs.
        var runs: [(start: Int, end: Int, maxGrade: Double)] = []
        var current: (start: Int, end: Int, maxGrade: Double)?
        for (index, grade) in grades.enumerated() {
            if grade > maxGradePercent {
                if var run = current {
                    run.end = index
                    run.maxGrade = max(run.maxGrade, grade)
                    current = run
                } else {
                    current = (index, index, grade)
                }
            } else if let run = current {
                runs.append(run)
                current = nil
            }
        }
        if let run = current {
            runs.append(run)
        }

        // Runs closer together than one window are one climb.
        var merged: [(start: Int, end: Int, maxGrade: Double)] = []
        for run in runs {
            if let last = merged.last, distances[run.start] - distances[last.end] < windowMeters {
                merged[merged.count - 1] = (last.start, run.end, max(last.maxGrade, run.maxGrade))
            } else {
                merged.append(run)
            }
        }

        return merged.compactMap { run in
            let startMeters = distances[run.start]
            let endMeters = distances[run.end]
            guard endMeters - startMeters >= 10 else { return nil }
            let middle = (startMeters + endMeters) / 2
            let centre = distances.indices.min { abs(distances[$0] - middle) < abs(distances[$1] - middle) }!
            return SteepSection(
                startMeters: startMeters,
                endMeters: endMeters,
                maxGradePercent: run.maxGrade,
                center: points[centre].coordinate
            )
        }
    }

    /// Distance from the start of the route to each point, in metres.
    public static func cumulativeDistances(_ points: [CoursePoint]) -> [Double] {
        var total = 0.0
        var result = [0.0]
        for (previous, next) in zip(points, points.dropFirst()) {
            total += Geodesy.distance(from: previous.coordinate, to: next.coordinate)
            result.append(total)
        }
        return result
    }

    /// Uphill grade in percent at each point, measured over a `windowMeters` stretch of route centred on it.
    /// Downhill counts as zero. Returns an empty array when any point has no height.
    public static func uphillGrades(
        _ points: [CoursePoint],
        distances: [Double],
        windowMeters: Double
    ) -> [Double] {
        guard points.count >= 2, points.allSatisfy({ $0.elevation != nil }) else { return [] }
        let heights = points.map { $0.elevation! }
        let last = points.count - 1
        let half = windowMeters / 2

        var grades: [Double] = []
        grades.reserveCapacity(points.count)
        var before = 0 // first point within half a window behind the current point
        var after = 0  // first point at least half a window ahead of the current point
        for index in 0...last {
            while before < index && distances[index] - distances[before] > half {
                before += 1
            }
            after = max(after, index)
            while after < last && distances[after] - distances[index] < half {
                after += 1
            }
            let run = distances[after] - distances[before]
            guard run >= 5 else {
                grades.append(0)
                continue
            }
            let grade = max(0, (heights[after] - heights[before]) / run * 100)
            grades.append(grade > implausibleGradePercent ? 0 : grade)
        }
        return grades
    }
}
