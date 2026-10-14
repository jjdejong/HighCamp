import XCTest
@testable import BaseCampCore

final class MapPlaceTests: XCTestCase {
    func testCapitalNamesAreShownInTitleCase() {
        XCTAssertEqual(MapPlace.displayName("SAINT-ÉGRÈVE"), "Saint-Égrève")
        XCTAssertEqual(MapPlace.displayName("NOTRE-DAME-DE-L'OSIER"), "Notre-Dame-de-l'Osier")
        XCTAssertEqual(MapPlace.displayName("SAINT-MARTIN-D'HÈRES"), "Saint-Martin-d'Hères")
        XCTAssertEqual(MapPlace.displayName("LA RIVIÈRE"), "La Rivière")
        XCTAssertEqual(MapPlace.displayName("L'ALBENC"), "L'Albenc")
        XCTAssertEqual(MapPlace.displayName("Le Puy-en-Velay"), "Le Puy-en-Velay")
        XCTAssertEqual(MapPlace.displayName("A7"), "A7")
        XCTAssertEqual(MapPlace.displayName("COURS JEAN JAURÈS (D 1075)"), "Cours Jean Jaurès (D 1075)")
        XCTAssertEqual(MapPlace.displayName("ROUTE DU PONT DE L’OULE"), "Route du Pont de l’Oule")
        XCTAssertEqual(MapPlace.displayName("LIGNE DE LYON À MARSEILLE"), "Ligne de Lyon à Marseille")
    }

    func testMergingKeepsTheMostImportantOfTheSameNameNearby() {
        let grenoble = Coordinate(latitude: 45.188, longitude: 5.736)
        let nearby = Coordinate(latitude: 45.19, longitude: 5.72)
        let far = Coordinate(latitude: 45.5, longitude: 5.736)
        let merged = MapPlace.merged([
            MapPlace(name: "Grenoble", coordinate: nearby, rank: 0, size: 0x0B),
            MapPlace(name: "Fontaine", coordinate: nearby, rank: 3, size: 0x0B),
            MapPlace(name: "Grenoble", coordinate: grenoble, rank: 3, size: 0x04),
            MapPlace(name: "Grenoble", coordinate: far, rank: 1, size: 0x0B),
        ])
        XCTAssertEqual(merged.map(\.name), ["Grenoble", "Fontaine", "Grenoble"])
        XCTAssertEqual(merged[0].coordinate, grenoble)
        XCTAssertEqual(merged[2].coordinate, far)
    }
}
