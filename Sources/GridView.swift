import AppKit

protocol GridViewDelegate: AnyObject {
    func gridView(_ grid: GridView, open index: Int)
    func gridView(_ grid: GridView, didFocus index: Int)
    func gridView(_ grid: GridView, keyDown event: NSEvent) -> Bool
    func gridView(_ grid: GridView, menuFor index: Int) -> NSMenu?
}

/// Thumbnails of every photo, with stars and saved marks. Click one to open it.
/// Lives inside an NSScrollView; only the cells on screen are drawn and loaded.
final class GridView: NSView {
    struct Marks {
        var rating = 0
        var saved = false
        var quarterTurns = 0
    }

    weak var delegate: GridViewDelegate?
    let thumbnails = ThumbnailLoader()
    var marks: (URL) -> Marks = { _ in Marks() }
    var onThumbnailSizeChange: ((CGFloat) -> Void)?

    var photos: [URL] = [] {
        didSet {
            indexByURL = Dictionary(photos.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            relayout()
        }
    }
    var focusIndex = 0 { didSet { if focusIndex != oldValue { needsDisplay = true } } }
    /// Target cell width in points.
    var thumbnailSize: CGFloat = 200 { didSet { if thumbnailSize != oldValue { relayout() } } }

    private var indexByURL: [URL: Int] = [:]
    private var columns = 1
    private var cell = CGSize(width: 200, height: 176)
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private var pressedIndex: Int?
    private var trackingArea: NSTrackingArea?
    private let padding: CGFloat = 20
    private let spacing: CGFloat = 14
    private let labelHeight: CGFloat = 20

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumbnails.onLoad = { [weak self] url in self?.thumbnailLoaded(url) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let clip = superview else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: clip)
        relayout()
    }

    @objc private func clipResized() { relayout() }

    // MARK: Layout

    func relayout() {
        guard let clip = superview else { return }
        let width = clip.bounds.width
        columns = max(1, Int((width - 2 * padding + spacing) / (thumbnailSize + spacing)))
        let cellWidth = floor((width - 2 * padding - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        cell = CGSize(width: cellWidth, height: cellWidth + labelHeight)  // square: suits vertical and horizontal shots alike
        let rows = (photos.count + columns - 1) / columns
        let content = 2 * padding + CGFloat(rows) * cell.height + CGFloat(max(rows - 1, 0)) * spacing
        setFrameSize(NSSize(width: width, height: max(clip.bounds.height, content)))
        needsDisplay = true
    }

    private func rect(for index: Int) -> CGRect {
        let row = index / columns, column = index % columns
        return CGRect(x: padding + CGFloat(column) * (cell.width + spacing), y: padding + CGFloat(row) * (cell.height + spacing),
                      width: cell.width, height: cell.height)
    }

    private func index(at p: CGPoint) -> Int? {
        guard p.x >= padding, p.y >= padding else { return nil }
        let column = Int((p.x - padding) / (cell.width + spacing)), row = Int((p.y - padding) / (cell.height + spacing))
        let i = row * columns + column
        guard column < columns, photos.indices.contains(i), rect(for: i).contains(p) else { return nil }
        return i
    }

    private func indexes(in r: CGRect) -> Range<Int> {
        let rowHeight = cell.height + spacing
        let first = max(0, Int((r.minY - padding) / rowHeight)), last = max(0, Int((r.maxY - padding) / rowHeight))
        let low = min(first * columns, photos.count), high = min((last + 1) * columns, photos.count)
        return low..<max(low, high)
    }

    func scrollToFocus() {
        guard photos.indices.contains(focusIndex) else { return }
        scrollToVisible(rect(for: focusIndex).insetBy(dx: 0, dy: -spacing))
    }

    /// Puts the focused photo in the middle of the window, e.g. when coming back from the photo view.
    func centerOnFocus() {
        guard let scrollView = enclosingScrollView, photos.indices.contains(focusIndex) else { return }
        let clip = scrollView.contentView
        let y = min(max(rect(for: focusIndex).midY - clip.bounds.height / 2, 0), max(frame.height - clip.bounds.height, 0))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func redraw(_ url: URL) {
        if let i = indexByURL[url] { setNeedsDisplay(rect(for: i).insetBy(dx: -8, dy: -8)) }
    }

    func resizeThumbnails(by factor: CGFloat) {
        thumbnailSize = min(max(thumbnailSize * factor, 110), 480)
        scrollToFocus()
        onThumbnailSizeChange?(thumbnailSize)
    }

    private func thumbnailLoaded(_ url: URL) { redraw(url) }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressedIndex = index(at: convert(event.locationInWindow, from: nil))
        if let i = pressedIndex { focus(i) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedIndex = nil }
        guard let i = pressedIndex, index(at: convert(event.locationInWindow, from: nil)) == i else { return }
        delegate?.gridView(self, open: i)
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
        hoverIndex = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        focus(i)
        return delegate?.gridView(self, menuFor: i)
    }

    override func magnify(with event: NSEvent) {
        resizeThumbnails(by: 1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: move(by: -1)
        case 124: move(by: 1)
        case 125: move(by: columns)
        case 126: move(by: -columns)
        case 115: move(by: -focusIndex)                        // Home
        case 119: move(by: photos.count - 1 - focusIndex)      // End
        case 36, 76, 49: if photos.indices.contains(focusIndex) { delegate?.gridView(self, open: focusIndex) }
        default:
            if delegate?.gridView(self, keyDown: event) != true { super.keyDown(with: event) }
        }
    }

    private func move(by delta: Int) {
        guard !photos.isEmpty else { return }
        let i = min(max(focusIndex + delta, 0), photos.count - 1)
        guard i != focusIndex else { return }
        focus(i)
        scrollToFocus()
    }

    private func focus(_ i: Int) {
        focusIndex = i
        delegate?.gridView(self, didFocus: i)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.09, alpha: 1).setFill()
        dirtyRect.fill()
        for i in indexes(in: dirtyRect) where rect(for: i).insetBy(dx: -8, dy: -8).intersects(dirtyRect) {
            drawCell(i, ctx)
        }
        requestThumbnails()
    }

    /// Loads what's on screen first, then a screen above and below; drops queued work for anything further.
    private func requestThumbnails() {
        let visible = visibleRect
        let nearby = indexes(in: visible.insetBy(dx: 0, dy: -visible.height))
        thumbnails.keepPending(Set(nearby.map { photos[$0] }))
        for i in indexes(in: visible) { thumbnails.request(photos[i], priority: .high) }
        for i in nearby { thumbnails.request(photos[i], priority: .low) }
    }

    private func drawCell(_ i: Int, _ ctx: CGContext) {
        let r = rect(for: i)
        let url = photos[i]
        let marks = marks(url)
        let focused = i == focusIndex
        if focused || i == hoverIndex {
            (focused ? NSColor.controlAccentColor.withAlphaComponent(0.3) : NSColor(white: 1, alpha: 0.07)).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: -6, dy: -6), xRadius: 8, yRadius: 8).fill()
        }

        let area = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - labelHeight)
        var imageRect = area.insetBy(dx: area.width * 0.12, dy: 0)
        if let image = thumbnails.thumbnail(for: url) {
            imageRect = draw(image, fittedIn: area, quarterTurns: marks.quarterTurns, ctx)
        } else {
            NSColor(white: 1, alpha: 0.05).setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: 4, yRadius: 4).fill()
        }
        if focused {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: imageRect.insetBy(dx: -1.5, dy: -1.5))
            outline.lineWidth = 3
            outline.stroke()
        }
        if marks.saved {
            let d: CGFloat = 20
            let dot = CGRect(x: imageRect.maxX - d - 6, y: imageRect.minY + 6, width: d, height: d)
            NSColor(red: 0.16, green: 0.6, blue: 0.3, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: dot).fill()
            let check = NSAttributedString(string: "✓", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                                                     .foregroundColor: NSColor.white])
            let size = check.size()
            check.draw(at: CGPoint(x: dot.midX - size.width / 2, y: dot.midY - size.height / 2))
        }
        if marks.rating > 0 {
            let stars = String(repeating: "★", count: marks.rating)
            Pill.draw(stars, at: CGPoint(x: imageRect.minX + 6, y: imageRect.maxY - Pill.size(stars, fontSize: 10).height - 6),
                      color: .systemYellow, fontSize: 10)
        }

        let label = NSAttributedString(string: url.lastPathComponent, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: focused ? .semibold : .regular),
            .foregroundColor: focused ? NSColor.white : NSColor(white: 0.55, alpha: 1),
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: r.midX - size.width / 2, y: area.maxY + 4))
    }

    /// Draws `image` turned clockwise by `quarterTurns`, as large as fits in `area`; returns where it went.
    private func draw(_ image: CGImage, fittedIn area: CGRect, quarterTurns: Int, _ ctx: CGContext) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let shown = quarterTurns % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let s = min(area.width / shown.width, area.height / shown.height)
        let fit = CGRect(x: area.midX - shown.width * s / 2, y: area.midY - shown.height * s / 2,
                         width: shown.width * s, height: shown.height * s)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: fit.midX, y: fit.midY)
        ctx.rotate(by: CGFloat(quarterTurns) * .pi / 2)  // clockwise in this flipped view
        ctx.scaleBy(x: s, y: -s)                          // and right side up
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
        return fit
    }
}

/// Grid thumbnails, made in the background and kept in a size-limited cache.
final class ThumbnailLoader {
    static let maxPixelSize = 512

    var onLoad: ((URL) -> Void)?

    private let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 250 << 20
        return cache
    }()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pending: [URL: Operation] = [:]
    /// Photos that couldn't be read, so they aren't retried on every redraw.
    private var failed: Set<URL> = []

    func thumbnail(for url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }

    /// Calls `onLoad` on the main thread when done.
    func request(_ url: URL, priority: Operation.QueuePriority) {
        guard thumbnail(for: url) == nil, !failed.contains(url) else { return }
        if let op = pending[url] {
            if op.queuePriority.rawValue < priority.rawValue { op.queuePriority = priority }
            return
        }
        let op = BlockOperation {
            let image = PhotoDecoder.thumbnail(of: url, maxPixelSize: Self.maxPixelSize)
            DispatchQueue.main.async { self.finish(url, image) }
        }
        op.queuePriority = priority
        pending[url] = op
        queue.addOperation(op)
    }

    /// Cancels queued thumbnails for everything not in `urls`.
    func keepPending(_ urls: Set<URL>) {
        for (url, op) in pending where !urls.contains(url) {
            op.cancel()
            pending[url] = nil
        }
    }

    func removeAll() {
        queue.cancelAllOperations()
        pending = [:]
        failed = []
        cache.removeAllObjects()
    }

    private func finish(_ url: URL, _ image: CGImage?) {
        pending[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        } else {
            failed.insert(url)
        }
        onLoad?(url)
    }
}
