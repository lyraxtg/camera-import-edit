import AppKit

enum ViewMode: String {
    case photo, grid
}

enum HUDItem: Hashable {
    case mode(ViewMode)
    case rotation, ratio, quality, destination
    case star(Int)
}

struct HUDInfo {
    var mode = ViewMode.photo
    var name = ""
    var position = ""
    var rating = 0
    var savedCount = 0
    var rotation = "0°"
    var ratio = ""
    var quality = ""
    var destination = ""
}

protocol StatusBarDelegate: AnyObject {
    func statusBar(_ bar: StatusBarView, clicked item: HUDItem, in rect: CGRect)
}

/// The bar along the bottom: view switch, which photo, its stars and saved mark, clickable settings, key hints.
final class StatusBarView: NSView {
    static let height: CGFloat = 56

    weak var delegate: StatusBarDelegate?
    var hud = HUDInfo() { didSet { needsDisplay = true } }

    private var itemRects: [HUDItem: CGRect] = [:]
    private var hovered: HUDItem? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private let margin: CGFloat = 16

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let item = item(at: p), let rect = itemRects[item] { delegate?.statusBar(self, clicked: item, in: rect) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = item(at: convert(event.locationInWindow, from: nil))
        (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        NSCursor.arrow.set()
    }

    private func item(at p: CGPoint) -> HUDItem? {
        itemRects.first { $0.value.contains(p) }?.key
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        itemRects = [:]

        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                     .foregroundColor: NSColor.white]
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                     .foregroundColor: NSColor(white: 0.6, alpha: 1)]
        let chevron: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                      .foregroundColor: NSColor(white: 0.55, alpha: 1)]
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                   .foregroundColor: NSColor(white: 0.5, alpha: 1)]
        let lineY: CGFloat = 9
        var x = margin

        // Grid | Photo switch.
        let segments: [(ViewMode, String, String)] = [(.grid, "square.grid.2x2", "Grid"), (.photo, "photo", "Photo")]
        let switchRect = CGRect(x: x, y: 4, width: 150, height: 24)
        NSColor(white: 1, alpha: 0.07).setFill()
        NSBezierPath(roundedRect: switchRect, xRadius: 6, yRadius: 6).fill()
        for (i, (mode, symbol, title)) in segments.enumerated() {
            let rect = CGRect(x: switchRect.minX + CGFloat(i) * 75, y: switchRect.minY, width: 75, height: 24)
            let active = hud.mode == mode
            if active || hovered == .mode(mode) {
                NSColor(white: 1, alpha: active ? 0.2 : 0.1).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            let color = active ? NSColor.white : NSColor(white: 0.6, alpha: 1)
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config) {
                image.draw(in: CGRect(x: rect.minX + 12, y: rect.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                           .foregroundColor: color])
                .draw(at: CGPoint(x: rect.minX + 30, y: rect.minY + 4))
            itemRects[.mode(mode)] = rect
        }
        x = switchRect.maxX + 20

        // Photo, position, stars (clickable), saved mark.
        if !hud.name.isEmpty {
            for (text, attributes) in [(hud.name, strong), (hud.position, normal)] {
                let string = NSAttributedString(string: text, attributes: attributes)
                string.draw(at: CGPoint(x: x, y: lineY))
                x += string.size().width + 18
            }
            let lit: Int
            if case .star(let n) = hovered { lit = n } else { lit = hud.rating }
            for n in 1...5 {
                let color: NSColor = n <= lit ? .systemYellow : NSColor(white: 0.4, alpha: 1)
                let star = NSAttributedString(string: n <= lit ? "★" : "☆",
                                              attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: color])
                let size = star.size()
                itemRects[.star(n)] = CGRect(x: x - 3, y: 4, width: size.width + 6, height: 24)
                star.draw(at: CGPoint(x: x, y: lineY - 2))
                x += size.width + 4
            }
            if hud.savedCount > 0 {
                let saved = hud.savedCount == 1 ? "✓ Saved" : "✓ Saved ×\(hud.savedCount)"
                NSAttributedString(string: saved, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                               .foregroundColor: NSColor.systemGreen])
                    .draw(at: CGPoint(x: x + 14, y: lineY))
            }
        }

        // Settings, each a clickable menu. Rotation and ratio only matter in the photo view.
        var right = bounds.maxX - margin + 8
        var items: [(HUDItem, String, String)] = [(.destination, "Save to", hud.destination), (.quality, "Quality", hud.quality)]
        if hud.mode == .photo { items += [(.ratio, "Ratio", hud.ratio), (.rotation, "Rotate", hud.rotation)] }
        for (item, key, value) in items {
            let text = NSMutableAttributedString(string: key + "  ", attributes: normal)
            text.append(NSAttributedString(string: value, attributes: strong))
            text.append(NSAttributedString(string: "  ▼", attributes: chevron))
            let size = text.size()
            let rect = CGRect(x: right - size.width - 16, y: 4, width: size.width + 16, height: 24)
            if hovered == item {
                NSColor(white: 1, alpha: 0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            text.draw(at: CGPoint(x: rect.minX + 8, y: lineY))
            itemRects[item] = rect
            right = rect.minX - 4
        }

        let hints: String
        switch hud.mode {
        case .photo:
            hints = "← →  browse     drag  crop     ⏎  save     F  save whole     1–5  stars     R  rotate 90°     [ ]  straighten     "
                + "⌥ drag  level     Z ⇧Z  zoom     Space  100%     A  ratio     X  swap     G  grid     ⌘⌫  trash     Esc  back"
        case .grid:
            hints = "click · ⏎  open     arrows  move     1–5  stars     F  save whole photo     R  rotate 90°     "
                + "pinch · ⌘= ⌘−  thumbnail size     ⌘⌫  trash     ⌘Z  undo     G  photo view"
        }
        NSAttributedString(string: hints, attributes: hint).draw(at: CGPoint(x: margin, y: 34))
    }
}

/// Short messages at the top of the window. Lets clicks through.
final class ToastView: NSView {
    private var message: (text: String, isError: Bool)?
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, isError: Bool = false, duration: TimeInterval = 2.5) {
        message = (text, isError)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.message = nil
            self?.needsDisplay = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let message else { return }
        let fill: NSColor = message.isError ? NSColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 0.95)
                                            : NSColor(white: 0.18, alpha: 0.95)
        let size = Pill.size(message.text, fontSize: 14)
        Pill.draw(message.text, at: CGPoint(x: bounds.midX - size.width / 2, y: 24), fill: fill, fontSize: 14)
    }
}

/// Rounded label used for badges, sizes and messages.
enum Pill {
    private static func string(_ text: String, fontSize: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                                                      .foregroundColor: color])
    }

    static func size(_ text: String, fontSize: CGFloat = 12) -> CGSize {
        let size = string(text, fontSize: fontSize, color: .white).size()
        return CGSize(width: size.width + fontSize * 1.6, height: size.height + fontSize * 0.8)
    }

    @discardableResult
    static func draw(_ text: String, at origin: CGPoint, fill: NSColor = NSColor.black.withAlphaComponent(0.7),
                     color: NSColor = .white, fontSize: CGFloat = 12) -> CGRect {
        let box = CGRect(origin: origin, size: size(text, fontSize: fontSize))
        fill.setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string(text, fontSize: fontSize, color: color).draw(at: CGPoint(x: box.minX + fontSize * 0.8, y: box.minY + fontSize * 0.4))
        return box
    }
}
