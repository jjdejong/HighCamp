import BaseCampCore
import XCTest

/// Tunnels and bridges: found in BRouter's answer, kept with each leg, and their heights drawn straight across, since
/// a terrain model gives the ground above a tunnel and, without bridges, the valley under one.
final class StructureTests: XCTestCase {
    /// A point every 0.0001° of latitude north from 45° N (about 11 m apart).
    private func place(_ index: Int) -> Coordinate {
        Coordinate(latitude: 45 + Double(index) * 0.0001, longitude: 5)
    }

    func testHeightsInsideAStretchAreLevelledBetweenItsEnds() throws {
        let distances = [0.0, 10, 20, 30, 40, 50]
        let heights: [Double?] = [100, 101, 120, 125, 104, 105]
        let levelled = Structures.level(heights, at: distances, over: [15...35])
        // The ends are the last point before the stretch and the first after it: 101 at 10 m, 104 at 40 m.
        XCTAssertEqual(try XCTUnwrap(levelled[2]), 102, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(levelled[3]), 103, accuracy: 0.001)
        XCTAssertEqual(levelled[0], 100)
        XCTAssertEqual(levelled[5], 105)
        // No height at an end: left as it was.
        XCTAssertEqual(Structures.level([nil, 101, 120, 125, 104, 105], at: distances, over: [0...15])[1], 101)
    }

    func testBRoutersAnswerSaysWhereTheTunnelsAreAndLevelsThem() throws {
        // Five points; the way from the 2nd to the 4th point is a tunnel. BRouter's message rows end where the way
        // changes, giving the length since the previous row and the way's tags.
        let coordinates = (0..<5).map { place($0) }
        let heights = [500.0, 502, 530, 506, 508]
        let geometry = zip(coordinates, heights).map { "[\($0.longitude),\($0.latitude),\($1)]" }.joined(separator: ",")
        func row(_ index: Int, _ length: Int, _ tags: String) -> String {
            "[\"\(Int((coordinates[index].longitude * 1_000_000).rounded()))\",\"\(Int((coordinates[index].latitude * 1_000_000).rounded()))\",\"0\",\"\(length)\",\"\(tags)\"]"
        }
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"track-length":"44","filtered ascend":"8",
        "messages":[["Longitude","Latitude","Elevation","Distance","WayTags"],\(row(1, 11, "highway=track")),\(row(3, 22, "highway=track tunnel=yes")),\(row(4, 11, "highway=track"))]},
        "geometry":{"type":"LineString","coordinates":[\(geometry)]}}]}
        """
        let route = try BRouterClient.parse(Data(json.utf8))
        let tunnel = try XCTUnwrap(route.structures.first)
        XCTAssertEqual(route.structures.count, 1)
        XCTAssertEqual(tunnel.lowerBound, Geodesy.distance(from: coordinates[0], to: coordinates[1]), accuracy: 0.01)
        XCTAssertEqual(tunnel.upperBound, Geodesy.distance(from: coordinates[0], to: coordinates[3]), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(route.points[2].elevation), 504, accuracy: 0.01)
    }

    func testAnAnswerWithoutMessagesHasNoStructures() throws {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[5,45,1],[5,45.001,2]]}}]}"#
        XCTAssertEqual(try BRouterClient.parse(Data(json.utf8)).structures, [])
    }

    func testTerrainHeightsAreLevelledAcrossTheStructuresToo() async throws {
        struct Source: RouteSource {
            func route(via points: [Coordinate], nogos: [NoGo]) async throws -> RouteGeometry {
                var geometry = RouteGeometry(points: (0..<5).map { CoursePoint(coordinate: Coordinate(latitude: 45 + Double($0) * 0.0001, longitude: 5)) },
                                             lengthMeters: 44, ascentMeters: 0)
                geometry.structures = [10...35]
                return geometry
            }
        }
        let elevated = ElevatedRouteSource(base: Source()) { coordinates in coordinates.indices.map { $0 == 2 ? 560.0 : 500 + Double($0) } }
        let route = try await elevated.route(via: [], nogos: [])
        XCTAssertEqual(try XCTUnwrap(route.points[2].elevation), 502, accuracy: 0.01)
    }

    func testALegKeepsItsStructuresFromItsFirstStop() throws {
        let start = place(0), end = place(10)
        // The router's line begins one point (about 11 m) past the start stop.
        let line = (1...10).map { RoutePoint(coordinate: place($0), elevation: 500) }
        let leg = RouteLeg.calculated(line: line, from: start, to: end, profileID: nil, structures: [20...40])
        let gap = try XCTUnwrap(leg.startGap)
        let stretch = try XCTUnwrap(leg.structures?.first)
        XCTAssertEqual(stretch.lowerBound, 20 + gap, accuracy: 0.01)
        XCTAssertEqual(stretch.upperBound, 40 + gap, accuracy: 0.01)
    }

    func testARoutesStructuresAreCountedFromItsStartAndTurnWithIt() throws {
        let stops = [RouteStop(coordinate: place(0)), RouteStop(coordinate: place(10)), RouteStop(coordinate: place(20))]
        var route = Route(name: "R", stops: stops, profileID: UUID())
        let line = (0...10).map { RoutePoint(coordinate: place(10 + $0), elevation: 500) }
        route.setLeg(at: 1, from: route.stops[1], to: route.stops[2],
                     .calculated(line: line, from: place(10), to: place(20), profileID: route.profileID, structures: [20...40]))
        let first = Geodesy.distance(from: place(0), to: place(10))
        let stretch = try XCTUnwrap(route.structureStretches.first)
        XCTAssertEqual(stretch.lowerBound, first + 20, accuracy: 0.01)
        XCTAssertEqual(stretch.upperBound, first + 40, accuracy: 0.01)

        let length = Geodesy.distance(from: place(0), to: place(20))
        let turned = try XCTUnwrap(route.reversed().structureStretches.first)
        XCTAssertEqual(turned.lowerBound, length - first - 40, accuracy: 0.1)
        XCTAssertEqual(turned.upperBound, length - first - 20, accuracy: 0.1)
    }

    func testAPlannedRouteSharesTheStructuresOutAmongItsLegs() throws {
        // Points 0.001° (111 m) apart, so the middle stop is found on its own point of the line.
        func place(_ index: Int) -> Coordinate { Coordinate(latitude: 45 + Double(index) * 0.001, longitude: 5) }
        let stops = [RouteStop(coordinate: place(0)), RouteStop(coordinate: place(10)), RouteStop(coordinate: place(20))]
        let line = (0...20).map { RoutePoint(coordinate: place($0), elevation: 500) }
        let leg = Geodesy.distance(from: place(0), to: place(10))
        // One structure inside the second leg, one across the middle stop.
        let route = Route.planned(name: "P", stops: stops, line: line, profileID: UUID(),
                                  structures: [(leg - 20)...(leg + 20), (leg + 50)...(leg + 70)])
        let first = try XCTUnwrap(route.legs[0].structures)
        let second = try XCTUnwrap(route.legs[1].structures)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].lowerBound, leg - 20, accuracy: 0.5)
        XCTAssertEqual(first[0].upperBound, leg, accuracy: 0.5)
        XCTAssertEqual(second.map(\.lowerBound), [0, 50], accuracy: 0.5)
        XCTAssertEqual(route.structureStretches.count, 3)
    }

    func testHeightsFromAModelAreLevelledOnTheRoute() throws {
        let stops = [RouteStop(coordinate: place(0)), RouteStop(coordinate: place(10))]
        let line = (0...10).map { RoutePoint(coordinate: place($0), elevation: 500) }
        let route = Route.planned(name: "P", stops: stops, line: line, profileID: nil, structures: [25...65])
        // A model with a hump of 60 m over the tunnel.
        let heights: [Double?] = route.points.indices.map { index in (3...5).contains(index) ? 560 : 500 + Double(index) }
        let result = route.withElevations(heights, replaceExisting: true).0
        XCTAssertEqual(try XCTUnwrap(result.points[4].elevation), 504, accuracy: 0.01)

        let profile = route.withElevations(heights, replaceExisting: true).0.elevationProfile
        XCTAssertEqual(profile.map(\.value).max() ?? 0, 510, accuracy: 0.01)
        // A profile read from a model, as the track DEM's, is levelled over the same stretches.
        let raw = route.points.indices.map { ElevationProfilePoint(id: $0, distanceMeters: Double($0) * 11.12, value: heights[$0]!, coordinate: route.points[$0].coordinate) }
        XCTAssertEqual(raw.leveled(over: route.structureStretches).map(\.value).max() ?? 0, 510, accuracy: 0.01)
    }

    func testOldLegsReadWithoutStructures() throws {
        let leg = try JSONDecoder().decode(RouteLeg.self, from: Data(#"{"shape":[],"method":"calculated"}"#.utf8))
        XCTAssertNil(leg.structures)
        let again = try JSONDecoder().decode(RouteLeg.self, from: JSONEncoder().encode(RouteLeg(method: .calculated, structures: [1...2])))
        XCTAssertEqual(again.structures, [1...2])
    }
}

private func XCTAssertEqual(_ values: [Double], _ expected: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(values.count, expected.count, file: file, line: line)
    for (value, wanted) in zip(values, expected) {
        XCTAssertEqual(value, wanted, accuracy: accuracy, file: file, line: line)
    }
}
