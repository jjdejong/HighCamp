import XCTest
@testable import BaseCampCore

final class ReportLayoutTests: XCTestCase {
    func testPageHeightIsMeasuredInReportPoints() {
        // An A4 page with 18 points of margin: 559 by 806 printable, for a report 612 points wide.
        let height = ReportLayout.pageHeight(printableWidth: 559, printableHeight: 806, reportWidth: 612)

        XCTAssertEqual(height, 806 * 612 / 559, accuracy: 0.01)
    }

    func testWidePaperDoesNotEnlargeTheReport() {
        XCTAssertEqual(ReportLayout.pageHeight(printableWidth: 700, printableHeight: 500, reportWidth: 612), 500)
    }

    func testProfileMovesToASecondPageWhenTheReportIsTooTall() {
        XCTAssertTrue(ReportLayout.profileOnSecondPage(reportHeight: 950, pageHeight: 882))
    }

    func testProfileStaysOnTheFirstPageWhenItFits() {
        XCTAssertFalse(ReportLayout.profileOnSecondPage(reportHeight: 800, pageHeight: 882))
        XCTAssertFalse(ReportLayout.profileOnSecondPage(reportHeight: 882, pageHeight: 882))
    }
}
