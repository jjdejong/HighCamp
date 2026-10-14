import AppKit
import SwiftUI

/// The tooltips of the window's toolbar buttons. SwiftUI's `.help` is not shown for the buttons of a toolbar item
/// group, so the same text is also set on the AppKit toolbar items, found by their label.
enum ToolbarTooltips {
    static let text: [String: String] = [
        "Import": "Import GPX, KML, TCX or FIT files (⌘O)",
        "Export": "Save the library or the selected route or track",
        "Maps": "Maps in the shared map folder (⇧⌘M)",
        "Profile": "Show or hide the profile of the selected track or route under the map (⌥⌘P)",
        "Find": "Find a place and add it as a waypoint (⇧⌘F)",
        "Edge Activities": "Import activities (rides, runs, walks…) recorded on the Garmin Edge",
        "Map": "Base map, Garmin maps, detail and contour lines",
        "Measure": "Measure a distance by clicking the map (⌥⌘M)",
        "Plan Route": "Plan a route by clicking the map (⌥⌘R)",
        "Inspector": "Show or hide the inspector",
    ]

    static func help(_ label: String) -> String {
        text[label] ?? label
    }
}

/// Put in the window's view hierarchy: sets `ToolbarTooltips` on the toolbar items, again whenever the window
/// updates, since SwiftUI may replace the items when the toolbar changes.
struct ToolbarTooltipInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            context.coordinator.attach(to: view?.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if context.coordinator.window == nil {
            DispatchQueue.main.async { [weak view] in
                context.coordinator.attach(to: view?.window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        private var observer: Any?

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            apply()
        }

        private func apply() {
            guard let items = window?.toolbar?.items else { return }
            for item in items {
                guard let tip = ToolbarTooltips.text[item.label], item.toolTip != tip else { continue }
                item.toolTip = tip
                if let view = item.view {
                    Self.setToolTip(tip, on: view)
                }
            }
        }

        private static func setToolTip(_ tip: String, on view: NSView) {
            view.toolTip = tip
            for subview in view.subviews {
                setToolTip(tip, on: subview)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
