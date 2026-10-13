import Foundation

/// Round lengths for a map's scale bar.
public enum ScaleBar {
    /// The longest round length, 1, 2 or 5 times a power of ten, that is no more than `fraction` of `total`.
    /// The units are whatever `total` is in. Returns nil when there is nothing to measure.
    public static func roundLength(_ total: Double, fraction: Double) -> Double? {
        let target = total * fraction
        guard target > 0, target.isFinite else { return nil }
        let power = pow(10, floor(log10(target)))
        let mantissa = target / power
        let step: Double = mantissa >= 5 ? 5 : (mantissa >= 2 ? 2 : 1)
        return step * power
    }
}
