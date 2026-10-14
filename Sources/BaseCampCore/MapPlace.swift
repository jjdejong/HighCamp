import Foundation

/// A city, town or village name from a Garmin map.
public struct MapPlace: Equatable, Sendable {
    public let name: String
    public let coordinate: Coordinate
    /// The coarsest map level the place is on: the map maker's measure of its importance. Higher is more important.
    public let rank: Int
    /// The Garmin place type's first byte, 0x01 to 0x11: smaller is a bigger place. Breaks ties between ranks.
    public let size: Int

    public init(name: String, coordinate: Coordinate, rank: Int, size: Int) {
        self.name = name
        self.coordinate = coordinate
        self.rank = rank
        self.size = size
    }

    /// One place per name within 3 km, keeping the most important, most important first. A town is on several
    /// levels, and a map may name it more than once.
    public static func merged(_ places: [MapPlace]) -> [MapPlace] {
        let ordered = places.sorted { ($0.rank, -$0.size, $1.name) > ($1.rank, -$1.size, $0.name) }
        var kept: [String: [Coordinate]] = [:]
        var result: [MapPlace] = []
        for place in ordered {
            let near = kept[place.name, default: []].contains { Geodesy.distance(from: $0, to: place.coordinate) < 3_000 }
            guard !near else { continue }
            kept[place.name, default: []].append(place.coordinate)
            result.append(place)
        }
        return result
    }

    /// Map names are often in capitals (OFM writes "SAINT-ÉGRÈVE"). Such names are shown in title case, with the
    /// small words of French and other place names kept small: "Saint-Égrève", "Notre-Dame-de-l'Osier". Names
    /// already in mixed case are kept as they are.
    public static func displayName(_ name: String) -> String {
        guard name == name.uppercased(), name != name.lowercased() else { return name }
        let small: Set<String> = [
            "de", "des", "du", "la", "le", "les", "en", "sur", "sous", "lès", "lez", "et", "aux", "au", "à",
            "y", "del", "di", "da", "von", "am", "im", "an", "der",
        ]
        // "d" and "l" are small only as elisions, before an apostrophe; "D 1075" is a road number.
        let elisions: Set<String> = ["d", "l"]
        var result = ""
        var word = ""
        var first = true
        func flush(before next: Character?) {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            let elided = elisions.contains(lower) && (next == "'" || next == "’")
            result += !first && (small.contains(lower) || elided) ? lower : lower.prefix(1).uppercased() + lower.dropFirst()
            first = false
            word = ""
        }
        for character in name {
            if character.isLetter {
                word.append(character)
            } else {
                flush(before: character)
                result.append(character)
            }
        }
        flush(before: nil)
        return result
    }
}
