import Foundation

/// How a map on the Edge got there. Only custom maps may be deleted from the app.
public enum DeviceMapKind: Equatable, Sendable {
    /// Ships with the Edge: `gmapbmap.img` and `gmaptz.img`.
    case builtIn
    /// A purchased map: a `D...A.img` file, or any map with a `.gma` unlock file beside it.
    case licensed
    /// A map copied to the device by the user.
    case custom

    public var canDelete: Bool {
        self == .custom
    }

    private static let builtInNames: Set<String> = ["gmapbmap.img", "gmaptz.img"]

    /// Classifies a map from its file name and the lowercased names of the other files in its folder.
    public static func classify(name: String, siblings: Set<String>) -> DeviceMapKind {
        let lower = name.lowercased()
        if builtInNames.contains(lower) {
            return .builtIn
        }
        let stem = lower.hasSuffix(".img") ? String(lower.dropLast(4)) : lower
        if siblings.contains(stem + ".gma") {
            return .licensed
        }
        if lower.range(of: #"^d\d+a\.img$"#, options: .regularExpression) != nil {
            return .licensed
        }
        return .custom
    }
}
