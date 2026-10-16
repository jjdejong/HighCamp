import AppKit
import BaseCampCore
import MapKit

/// The label shown beside the pointer over a marker or a line that has something to say: a steep stretch's grades,
/// how far a stop is from the router's ways, a waypoint's name. HighCamp draws its own rather than using tooltips,
/// which wait a second, need the pointer on the small marker itself, and vanish whenever MapKit touches the view.
extension MapKitView.Coordinator {
    /// How long the pointer rests before the first label shows, so sweeping across the map does not flash them.
    private static let showDelay: TimeInterval = 0.25
    /// How long a label stays once the pointer has left what it describes, so a shaky hand does not lose it.
    private static let hideDelay: TimeInterval = 0.6

    /// Shows, moves or hides the label for what is under `point`; nil when the pointer is not over the map.
    func updateHoverTip(at point: CGPoint?, event: NSEvent, on map: MKMapView) {
        guard let point, let text = hoverText(at: point, event: event, on: map) else {
            scheduleHoverTipHide()
            return
        }
        hoverTipHide?.cancel()
        hoverTipHide = nil
        if let tip = hoverTip, tip.superview === map, !tip.isHidden {
            tip.show(text, near: point, in: map)
            return
        }
        let tip = hoverTip ?? MapTipView()
        hoverTip = tip
        tip.pending = (text, point)
        guard tip.showWork == nil else { return }
        let work = DispatchWorkItem { [weak tip, weak map] in
            guard let tip, let map, let (text, point) = tip.pending else { return }
            tip.showWork = nil
            tip.show(text, near: point, in: map)
        }
        tip.showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    func hideHoverTip() {
        hoverTipHide?.cancel()
        hoverTipHide = nil
        hoverTip?.hide()
    }

    private func scheduleHoverTipHide() {
        guard let tip = hoverTip else { return }
        // Not shown yet: forget it.
        tip.showWork?.cancel()
        tip.showWork = nil
        tip.pending = nil
        guard !tip.isHidden, tip.superview != nil, hoverTipHide == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.hideHoverTip() }
        hoverTipHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    /// A marker's title, a few points round it counting; else the tip of a line within a few points.
    private func hoverText(at point: CGPoint, event: NSEvent, on map: MKMapView) -> String? {
        if let pin = Self.marker(at: event, on: map, margin: 4), let title = pin.title, !title.isEmpty {
            return title
        }
        let lines = appliedLayers.values.flatMap(\.lines).filter { $0.tip != nil && $0.coordinates.count > 1 }
        guard !lines.isEmpty else { return nil }
        var best: (text: String, gap: CGFloat)?
        for line in lines {
            let points = line.coordinates.map { map.convert($0.clLocation, toPointTo: map) }
            for (a, b) in zip(points, points.dropFirst()) {
                let gap = Self.distance(from: point, toSegment: a, b)
                if gap <= 6, gap < (best?.gap ?? .infinity), let tip = line.tip {
                    best = (tip, gap)
                }
            }
        }
        return best?.text
    }
}

/// A small label over the map. It lets clicks through to the map under it.
final class MapTipView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    /// What to show once the pointer has rested.
    var pending: (String, CGPoint)?
    var showWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.isSelectable = false
        label.maximumNumberOfLines = 3
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Shows `text` above and to the right of `point`, kept inside the map.
    func show(_ text: String, near point: CGPoint, in map: MKMapView) {
        if superview !== map {
            removeFromSuperview()
            map.addSubview(self)
        }
        label.stringValue = text
        label.preferredMaxLayoutWidth = 380
        let size = label.fittingSize
        let padding = CGSize(width: 7, height: 4)
        let box = CGSize(width: ceil(size.width) + padding.width * 2, height: ceil(size.height) + padding.height * 2)
        label.frame = CGRect(x: padding.width, y: padding.height, width: ceil(size.width), height: ceil(size.height))
        // Clear of the pointer, above it; below it when there is no room above.
        var origin = CGPoint(x: point.x + 12, y: map.isFlipped ? point.y - 14 - box.height : point.y + 14)
        let bounds = map.bounds.insetBy(dx: 4, dy: 4)
        if origin.x + box.width > bounds.maxX { origin.x = max(bounds.minX, point.x - 12 - box.width) }
        if origin.y < bounds.minY || origin.y + box.height > bounds.maxY {
            origin.y = map.isFlipped ? point.y + 18 : point.y - 18 - box.height
        }
        frame = CGRect(origin: origin, size: box)
        isHidden = false
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        pending = nil
        isHidden = true
    }
}
