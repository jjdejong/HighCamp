import BaseCampCore
import XCTest

/// Route stops named from what the map shows at them, as BaseCamp names route points.
final class StopNameTests: XCTestCase {
    private let stop = Coordinate(latitude: 45.0, longitude: 5.0)

    /// A place `north` and `east` metres from the stop.
    private func at(north: Double, east: Double = 0) -> Coordinate {
        Coordinate(latitude: 45.0 + north / 111_320, longitude: 5.0 + east / (111_320 * cos(45.0 * .pi / 180)))
    }

    private func road(_ name: String, east: Double, isWater: Bool = false) -> NamedLine {
        NamedLine(name: name, coordinates: [at(north: -200, east: east), at(north: 200, east: east)], importance: 1, isWater: isWater)
    }

    private let village = MapPlace(name: "Pariset", coordinate: Coordinate(latitude: 45.005, longitude: 5.0), rank: 1, size: 0x0d)

    func testAPointOfInterestOnTheStopNamesIt() {
        let pass = MapPOI(type: 0x6406, coordinate: at(north: 20), name: "Col de l'Arc", priority: 1)
        let unnamed = MapPOI(type: 0x2f00, coordinate: at(north: 5), name: nil, priority: 0)
        XCTAssertEqual(StopNames.name(at: stop, points: [unnamed, pass], lines: [road("Rue Haute", east: 10)], places: [village], areas: []),
                       "Col de l'Arc")
        // What the map adds in brackets is left out.
        let busStop = MapPOI(type: 0x2f08, coordinate: at(north: 10), name: "Hauts de Seyssins (Bus T65,T65,193)", priority: 1)
        XCTAssertEqual(StopNames.name(at: stop, points: [busStop], lines: [], places: [], areas: []), "Hauts de Seyssins")
    }

    func testOtherwiseTheStreetOrPathItIsOn() {
        let name = StopNames.name(at: stop, points: [], lines: [road("Chemin des Vignes", east: 25), road("Rue Haute", east: 8),
                                                                road("Le Furon", east: 2, isWater: true)],
                                  places: [village], areas: [])
        XCTAssertEqual(name, "Rue Haute")
    }

    func testOtherwiseTheNearestVillageThenTheAreaItIsIn() {
        let forest = NamedArea(name: "Bois des Vouillants", kind: .nature,
                               rings: [[at(north: -500, east: -500), at(north: -500, east: 500), at(north: 500, east: 500), at(north: 500, east: -500)]])
        // A road 60 m away is too far; the village 556 m away names the stop before the forest it is in.
        XCTAssertEqual(StopNames.name(at: stop, points: [], lines: [road("Rue Haute", east: 60)], places: [village], areas: [forest]), "Pariset")
        let farVillage = MapPlace(name: "Lans", coordinate: Coordinate(latitude: 45.02, longitude: 5.0), rank: 1, size: 0x0d)
        XCTAssertEqual(StopNames.name(at: stop, points: [], lines: [], places: [farVillage], areas: [forest]), "Bois des Vouillants")
        XCTAssertEqual(StopNames.name(at: stop, points: [], lines: [], places: [farVillage], areas: []), "Lans")
        XCTAssertNil(StopNames.name(at: stop, points: [], lines: [], places: [], areas: []))
    }

    func testAMapNameGoesWhenTheStopMovesATypedOneStays() {
        var route = Route(name: "R", stops: [RouteStop(name: "Rue Haute", coordinate: stop, hasMapName: true),
                                             RouteStop(name: "Home", coordinate: at(north: 500))])
        route.moveStop(at: 0, to: at(north: 100))
        route.moveStop(at: 1, to: at(north: 600))
        XCTAssertTrue(route.stops[0].needsName)
        XCTAssertFalse(route.stops[0].hasMapName)
        XCTAssertEqual(route.stops[1].name, "Home")
    }

    func testStopsSavedBeforeHaveNoMapName() throws {
        let json = #"{"id":"A632A170-699F-4BE1-AA47-D6B233C31D9B","coordinate":{"latitude":45,"longitude":5}}"#
        let old = try JSONDecoder().decode(RouteStop.self, from: Data(json.utf8))
        XCTAssertFalse(old.hasMapName)
        XCTAssertTrue(old.needsName)
    }
}
