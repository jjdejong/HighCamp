import Foundation

/// How a printed report is split across pages. The report is laid out in points of its own width, and that
/// width is fitted to the printable width of the page.
public enum ReportLayout {
    /// The height of a page, in report points. A page wider than the report is not enlarged to fit it.
    public static func pageHeight(printableWidth: Double, printableHeight: Double, reportWidth: Double) -> Double {
        let scale = min(1, printableWidth / reportWidth)
        return printableHeight / scale
    }

    /// Whether the elevation profile goes on a second page: when the report with the profile is taller than a page.
    public static func profileOnSecondPage(reportHeight: Double, pageHeight: Double) -> Bool {
        reportHeight > pageHeight
    }
}
