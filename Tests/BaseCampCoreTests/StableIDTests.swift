import XCTest
@testable import BaseCampCore

final class StableIDTests: XCTestCase {
    func testTheSameTextGivesTheSameID() {
        XCTAssertEqual(UUID(stableFrom: "Courses/Test_Route_1.fit"), UUID(stableFrom: "Courses/Test_Route_1.fit"))
        XCTAssertNotEqual(UUID(stableFrom: "Courses/Test_Route_1.fit"), UUID(stableFrom: "Courses/Test_Route_2.fit"))
        XCTAssertNotEqual(UUID(stableFrom: "a"), UUID(stableFrom: "b"))
    }

    func testCourseNamesAreRead() throws {
        let points = [CoursePoint(coordinate: Coordinate(latitude: 45, longitude: 5)), CoursePoint(coordinate: Coordinate(latitude: 45.01, longitude: 5))]
        let data = try FITCourse.encode(name: "Col de Porte", points: points)

        XCTAssertEqual(try FITActivity.read(data, name: "Col_de_Porte").name, "Col de Porte")
    }
}
