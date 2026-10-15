import AppKit

protocol PhotoViewDelegate: AnyObject {
    func photoView(_ view: PhotoView, keyDown event: NSEvent) -> Bool
    func photoView(_ view: PhotoView, keyUp event: NSEvent) -> Bool
    /// A trackpad twist or a level line asks for a new straightening angle (degrees, clockwise).
    func photoView(_ view: PhotoView, straightenTo angle: Double)
    /// Zoomed in further than the preview can show sharply.
    func photoViewNeedsFullResolution(_ view: PhotoView)
}

/// Shows one photo and lets you crop, zoom and straighten it.
/// Rects are in pixels of the crop frame: the full-resolution photo after orientation, quarter turns and
/// straightening (see `PhotoInfo.size`).
final class PhotoView: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private enum Drag {
        case create(anchor: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(edges: Edges, original: CGRect)
        /// ⌥-drag along something that should be level; in view coordinates.
        case level(start: CGPoint)
    }

    weak var delegate: PhotoViewDelegate?
    private(set) var photo: LoadedPhoto?
    var selection: CGRect? { didSet { needsDisplay = true } }
    /// Width / height the selection is locked to, or nil for free.
    var ratio: CGFloat?
    var rating = 0 { didSet { needsDisplay = true } }
    var savedCount = 0 { didSet { needsDisplay = true } }
    /// Shown in place of the photo when there isn't one.
    var status: String? { didSet { needsDisplay = true } }
    /// The photo at full resolution (quarter turns applied), loaded on demand for zooming.
    var fullImage: CGImage? { didSet { needsDisplay = true } }
    /// Space held: 100% view that pans with the mouse.
    var isPeeking = false {
        didSet {
            guard isPeeking != oldValue else { return }
            if isPeeking, fullImage == nil { delegate?.photoViewNeedsFullResolution(self) }
            needsDisplay = true
            updateCursor()
        }
    }

    /// Magnification relative to fitting the window; 1 = fit.
    private var zoom: CGFloat = 1
    /// The frame point shown at the centre of the image area.
    private var focus = CGPoint.zero
    private var drag: Drag?
    private var selectionBeforeClick: CGRect?
    private var levelLine: (from: CGPoint, to: CGPoint)?
    private var gridUntil = Date.distantPast
    private var gridTimer: Timer?
    private var trackingArea: NSTrackingArea?

    private let margin: CGFloat = 16
    private let handleSize: CGFloat = 8
    private let grabDistance: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPhoto(_ photo: LoadedPhoto?) {
        self.photo = photo
        selection = nil
        fullImage = nil
        drag = nil
        levelLine = nil
        zoom = 1
        focus = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
        needsDisplay = true
    }

    /// Swaps in a sharper image of the same photo (the grid thumbnail is shown first while the
    /// preview loads) without touching the crop or zoom.
    func replacePreview(_ photo: LoadedPhoto) {
        self.photo = photo
        needsDisplay = true
    }

    var isZoomedIn: Bool { zoom > 1.001 }

    /// Changes the straightening angle, keeping the zoom and (as far as it still fits) the selection.
    func setAngle(_ angle: Double) {
        guard var photo, photo.info.angle != angle else { return }
        let old = photo.info.size
        photo.info.angle = angle
        self.photo = photo
        let new = photo.info.size
        let dx = (new.width - old.width) / 2, dy = (new.height - old.height) / 2
        if var r = selection?.offsetBy(dx: dx, dy: dy) {
            let k = min(1, new.width / r.width, new.height / r.height)
            if k < 1 {
                r = CGRect(x: r.midX - r.width * k / 2, y: r.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
            }
            r.origin = CGPoint(x: clamp(r.minX, 0, new.width - r.width), y: clamp(r.minY, 0, new.height - r.height))
            selection = r
        }
        focus = CGPoint(x: focus.x + dx, y: focus.y + dy)
        clampFocus()
        flashGrid()
    }

    var mouseLocation: CGPoint? {
        window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    // MARK: Selection

    func selectWholePhoto() {
        guard photo != nil else { return }
        let size = frameSize
        guard let r = ratio else {
            selection = CGRect(origin: .zero, size: size)
            return
        }
        var w = size.width, h = w / r
        if h > size.height { h = size.height; w = h * r }
        selection = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Reshapes the selection to `ratio`, keeping its centre and roughly its area.
    func conformSelectionToRatio() {
        guard let sel = selection, let r = ratio else { return }
        let size = frameSize
        var w = (sel.width * sel.height * r).squareRoot(), h = w / r
        if w > size.width { w = size.width; h = w / r }
        if h > size.height { h = size.height; w = h * r }
        selection = CGRect(x: clamp(sel.midX - w / 2, 0, size.width - w),
                           y: clamp(sel.midY - h / 2, 0, size.height - h), width: w, height: h)
    }

    // MARK: Zoom

    func zoomIn() { setZoom(nextZoom(in: true), anchor: nil) }
    func zoomOut() { setZoom(nextZoom(in: false), anchor: nil) }
    func zoomToFit() { setZoom(1, anchor: nil) }
    func zoomToActualSize() { setZoom(actualSizeZoom, anchor: mouseLocation) }

    /// One step in around `point`; from the maximum, back to fit.
    func zoomStepIn(at point: CGPoint?) {
        setZoom(zoom >= maxZoom - 0.001 ? 1 : nextZoom(in: true), anchor: point)
    }

    func zoomStepOut(at point: CGPoint?) {
        setZoom(nextZoom(in: false), anchor: point)
    }

    /// Magnification shown on screen, where 100% is one photo pixel per screen pixel.
    var zoomPercent: Int { Int((scale * backingScale * 100).rounded()) }

    /// ×1.5 per step, stopping exactly at 100% when a step would reach it or land near it.
    private func nextZoom(in zoomingIn: Bool) -> CGFloat {
        let target = zoomingIn ? zoom * 1.5 : zoom / 1.5
        let actual = actualSizeZoom
        if zoomingIn, zoom < actual * 0.99, target > actual * 0.8 { return actual }
        if !zoomingIn, zoom > actual * 1.01, target < actual * 1.25 { return actual }
        return target
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var actualSizeZoom: CGFloat { max(1, 1 / backingScale / fitScale) }
    private var maxZoom: CGFloat { max(1, 2 / backingScale / fitScale) }

    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint?) {
        guard photo != nil else { return }
        let area = imageArea
        let p = anchor.flatMap { area.contains($0) ? $0 : nil } ?? CGPoint(x: area.midX, y: area.midY)
        let f = framePoint(p)
        zoom = min(max(newZoom, 1), maxZoom)
        focus = CGPoint(x: f.x - (p.x - area.midX) / scale, y: f.y - (p.y - area.midY) / scale)
        clampFocus()
        requestFullResolutionIfNeeded()
        needsDisplay = true
        updateCursor()
    }

    /// Keeps the photo covering the image area when zoomed in, and centred when it's smaller.
    private func clampFocus() {
        let size = frameSize, area = imageArea, v = scale
        let halfW = area.width / 2 / v, halfH = area.height / 2 / v
        focus.x = size.width <= 2 * halfW ? size.width / 2 : clamp(focus.x, halfW, size.width - halfW)
        focus.y = size.height <= 2 * halfH ? size.height / 2 : clamp(focus.y, halfH, size.height - halfH)
    }

    private func requestFullResolutionIfNeeded() {
        guard let photo, fullImage == nil else { return }
        let previewDensity = CGFloat(photo.preview.width) / photo.info.turnedSize.width
        if scale * backingScale > previewDensity * 1.25 { delegate?.photoViewNeedsFullResolution(self) }
    }

    private func flashGrid() {
        gridUntil = Date().addingTimeInterval(1.5)
        gridTimer?.invalidate()
        gridTimer = Timer.scheduledTimer(withTimeInterval: 1.55, repeats: false) { [weak self] _ in self?.needsDisplay = true }
        needsDisplay = true
    }

    // MARK: Geometry

    private var frameSize: CGSize { photo?.info.size ?? .zero }

    private var imageArea: CGRect { bounds.insetBy(dx: margin, dy: margin) }

    /// View points per frame pixel when fitted.
    private var fitScale: CGFloat {
        let size = frameSize
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(imageArea.width / size.width, imageArea.height / size.height)
    }

    /// View points per frame pixel now.
    private var scale: CGFloat { fitScale * zoom }

    /// Where the whole frame sits in the view (may extend past the window when zoomed).
    private var displayRect: CGRect? {
        let size = frameSize
        guard size.width > 0, size.height > 0 else { return nil }
        let v = scale, area = imageArea
        return CGRect(x: area.midX - focus.x * v, y: area.midY - focus.y * v, width: size.width * v, height: size.height * v)
    }

    /// The frame at 100%, with the point under the mouse staying put.
    private var peekRect: CGRect? {
        guard photo != nil, let mouse = mouseLocation else { return nil }
        let f = clamped(framePoint(mouse))
        let v = 1 / backingScale
        return CGRect(x: mouse.x - f.x * v, y: mouse.y - f.y * v, width: frameSize.width * v, height: frameSize.height * v)
    }

    private func viewRect(_ r: CGRect, in frame: CGRect) -> CGRect {
        let v = frame.width / frameSize.width
        return CGRect(x: frame.minX + r.minX * v, y: frame.minY + r.minY * v, width: r.width * v, height: r.height * v)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        displayRect.map { viewRect(r, in: $0) } ?? .zero
    }

    private func framePoint(_ p: CGPoint) -> CGPoint {
        guard let frame = displayRect else { return .zero }
        return CGPoint(x: (p.x - frame.minX) / scale, y: (p.y - frame.minY) / scale)
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: clamp(p.x, 0, frameSize.width), y: clamp(p.y, 0, frameSize.height))
    }

    // MARK: Mouse and trackpad

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard photo != nil, !isPeeking, let frame = displayRect else { return }
        if event.clickCount == 2 {
            // The first click of a double-click may have cleared the crop; put it back.
            drag = nil
            selection = selectionBeforeClick
            zoomStepIn(at: p)
            return
        }
        selectionBeforeClick = selection
        if event.modifierFlags.contains(.option) {
            drag = .level(start: p)
            levelLine = (p, p)
            needsDisplay = true
            return
        }
        if let sel = selection {
            let r = viewRect(sel)
            let edges = edgesNear(p, r)
            if !edges.isEmpty {
                drag = .resize(edges: edges, original: sel)
                return
            }
            if r.contains(p) {
                drag = .move(start: framePoint(p), original: sel)
                NSCursor.closedHand.set()
                return
            }
        }
        selection = nil
        // Starting just outside the photo is allowed, so crops can begin exactly at its edge.
        guard imageArea.intersection(frame).insetBy(dx: -3 * grabDistance, dy: -3 * grabDistance).contains(p) else { return }
        drag = .create(anchor: clamped(framePoint(p)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let p = framePoint(point)
        switch drag {
        case .create(let anchor):
            selection = rect(from: anchor, to: clamped(p))
        case .move(let start, let o):
            let size = frameSize
            selection = CGRect(x: clamp(o.minX + p.x - start.x, 0, size.width - o.width),
                               y: clamp(o.minY + p.y - start.y, 0, size.height - o.height),
                               width: o.width, height: o.height)
        case .resize(let edges, let o):
            selection = resize(o, edges, to: clamped(p))
        case .level(let start):
            levelLine = (start, point)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = drag else { return }
        drag = nil
        if case .level(let start) = finished {
            levelLine = nil
            let end = convert(event.locationInWindow, from: nil)
            let dx = end.x - start.x, dy = end.y - start.y
            if let photo, hypot(dx, dy) > 20 {
                // Turn the photo so the line becomes exactly horizontal or vertical, whichever is nearer.
                var tilt = Double(atan2(dy, dx)) * 180 / .pi
                while tilt > 45 { tilt -= 90 }
                while tilt <= -45 { tilt += 90 }
                delegate?.photoView(self, straightenTo: photo.info.angle - tilt)
            }
            flashGrid()
            return
        }
        if let sel = selection, sel.width * scale < 4 || sel.height * scale < 4 {
            selection = nil  // a click, not a drag: just clears the crop
        }
        needsDisplay = true
        updateCursor()
    }

    override func magnify(with event: NSEvent) {
        guard photo != nil else { return }
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func rotate(with event: NSEvent) {
        guard let photo, !isPeeking else { return }
        // Halved so a comfortable twist gives fine control.
        delegate?.photoView(self, straightenTo: photo.info.angle - Double(event.rotation) * 0.5)
    }

    override func scrollWheel(with event: NSEvent) {
        guard photo != nil, !isPeeking else { return }
        if event.hasPreciseScrollingDeltas {
            // Trackpad: two-finger scroll pans.
            guard zoom > 1.001 else { return }
            focus.x -= event.scrollingDeltaX / scale
            focus.y -= event.scrollingDeltaY / scale
            clampFocus()
            requestFullResolutionIfNeeded()
            needsDisplay = true
        } else {
            // Mouse wheel zooms.
            setZoom(zoom * pow(1.15, event.scrollingDeltaY), anchor: convert(event.locationInWindow, from: nil))
        }
    }

    /// Rect spanned from `a` to `p`, honouring the ratio lock and the frame bounds.
    private func rect(from a: CGPoint, to p: CGPoint) -> CGRect {
        guard let r = ratio else {
            return CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
        }
        let size = frameSize
        let right = p.x >= a.x, down = p.y >= a.y
        var w = max(abs(p.x - a.x), abs(p.y - a.y) * r)
        w = min(w, right ? size.width - a.x : a.x, (down ? size.height - a.y : a.y) * r)
        let h = w / r
        return CGRect(x: right ? a.x : a.x - w, y: down ? a.y : a.y - h, width: w, height: h)
    }

    private func resize(_ o: CGRect, _ edges: Edges, to p: CGPoint) -> CGRect {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        guard let r = ratio else {
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if edges.contains(.left) { minX = p.x }
            if edges.contains(.right) { maxX = p.x }
            if edges.contains(.top) { minY = p.y }
            if edges.contains(.bottom) { maxY = p.y }
            return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        }
        if horizontal && vertical {
            // Corner: the opposite corner stays put.
            let anchor = CGPoint(x: edges.contains(.left) ? o.maxX : o.minX, y: edges.contains(.top) ? o.maxY : o.minY)
            return rect(from: anchor, to: p)
        }
        let size = frameSize
        if horizontal {
            // Side edge: the opposite edge stays put and the height follows, centred.
            let ax = edges.contains(.left) ? o.maxX : o.minX
            let right = p.x >= ax
            let w = min(abs(p.x - ax), right ? size.width - ax : ax, size.height * r)
            let h = w / r
            return CGRect(x: right ? ax : ax - w, y: clamp(o.midY - h / 2, 0, size.height - h), width: w, height: h)
        }
        let ay = edges.contains(.top) ? o.maxY : o.minY
        let down = p.y >= ay
        let h = min(abs(p.y - ay), down ? size.height - ay : ay, size.width / r)
        let w = h * r
        return CGRect(x: clamp(o.midX - w / 2, 0, size.width - w), y: down ? ay : ay - h, width: w, height: h)
    }

    private func edgesNear(_ p: CGPoint, _ r: CGRect) -> Edges {
        let t = grabDistance
        guard r.insetBy(dx: -t, dy: -t).contains(p) else { return [] }
        let dl = abs(p.x - r.minX), dr = abs(p.x - r.maxX), dt = abs(p.y - r.minY), db = abs(p.y - r.maxY)
        var edges: Edges = []
        if min(dl, dr) <= t { edges.insert(dl <= dr ? .left : .right) }
        if min(dt, db) <= t { edges.insert(dt <= db ? .top : .bottom) }
        return edges
    }

    // MARK: Cursor and hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if isPeeking { needsDisplay = true }
        updateCursor()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        guard drag == nil, let mouse = mouseLocation else { return }
        cursor(at: mouse).set()
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard photo != nil, !isPeeking, let frame = displayRect else { return .arrow }
        if let sel = selection {
            let r = viewRect(sel)
            let edges = edgesNear(p, r)
            if !edges.isEmpty { return resizeCursor(edges) }
            if r.contains(p) { return .openHand }
        }
        return imageArea.intersection(frame).contains(p) ? .crosshair : .arrow
    }

    private func resizeCursor(_ edges: Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.left), edges.contains(.right)) {
        case (true, _, true, _): position = .topLeft
        case (true, _, _, true): position = .topRight
        case (_, true, true, _): position = .bottomLeft
        case (_, true, _, true): position = .bottomRight
        case (true, _, _, _): position = .top
        case (_, true, _, _): position = .bottom
        case (_, _, true, _): position = .left
        default: position = .right
        }
        return .frameResize(position: position, directions: .all)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if delegate?.photoView(self, keyDown: event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if delegate?.photoView(self, keyUp: event) != true { super.keyUp(with: event) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.09, alpha: 1).setFill()
        bounds.fill()

        if photo != nil, let frame = displayRect {
            let topLeft = CGPoint(x: margin + 8, y: margin + 8)
            if isPeeking, fullImage != nil, let peek = peekRect {
                let area = bounds
                drawPhoto(in: peek, clip: area, ctx)
                if let sel = selection {
                    ctx.saveGState()
                    ctx.clip(to: area)
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                    ctx.setLineWidth(1)
                    ctx.stroke(viewRect(sel, in: peek))
                    ctx.restoreGState()
                }
                Pill.draw("100%", at: topLeft)
            } else {
                drawPhoto(in: frame, clip: imageArea, ctx)
                if levelLine != nil || Date() < gridUntil { drawGrid(frame, ctx) }
                if let sel = selection { drawSelection(sel, frame: frame, ctx) }
                if let line = levelLine { drawLevelLine(line, ctx) }
                if isPeeking {
                    Pill.draw("Loading 100%…", at: topLeft)
                } else if zoom > 1.001 {
                    Pill.draw("\(zoomPercent)%", at: topLeft)
                }
                drawBadges(on: imageArea.intersection(frame))
            }
        } else if let status {
            let text = NSAttributedString(string: status, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.6, alpha: 1),
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: imageArea.midX - size.width / 2, y: imageArea.midY - size.height / 2))
        }
    }

    /// Draws the photo with its frame at `frame`: straightened, and using only the on-screen part of
    /// whichever image (preview or full resolution) is sharp enough.
    private func drawPhoto(in frame: CGRect, clip: CGRect, _ ctx: CGContext) {
        guard let photo else { return }
        let info = photo.info
        let turned = info.turnedSize
        let v = frame.width / info.size.width
        let previewDensity = CGFloat(photo.preview.width) / turned.width
        let source: CGImage
        if let fullImage, isPeeking || v * backingScale > previewDensity { source = fullImage } else { source = photo.preview }
        let k = CGFloat(source.width) / turned.width
        let visible = clip.intersection(frame)
        guard !visible.isEmpty else { return }

        let theta = CGFloat(info.angle * .pi / 180)
        let frameCenter = CGPoint(x: info.size.width / 2, y: info.size.height / 2)
        let turnedCenter = CGPoint(x: turned.width / 2, y: turned.height / 2)

        // Map the visible corners back into the source image so only that part gets drawn.
        let c = cos(-theta), s = sin(-theta)
        let corners = [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.minY),
                       CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)].map { p in
            let f = CGPoint(x: (p.x - frame.minX) / v - frameCenter.x, y: (p.y - frame.minY) / v - frameCenter.y)
            return CGPoint(x: (f.x * c - f.y * s + turnedCenter.x) * k, y: (f.x * s + f.y * c + turnedCenter.y) * k)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -2, dy: -2)
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height)).integral
        guard !box.isEmpty, let piece = source.cropping(to: box) else { return }

        ctx.saveGState()
        ctx.clip(to: visible)
        ctx.interpolationQuality = theta == 0 && v / k * backingScale >= 1 ? .none : .high
        // Frame centre → view, then turn by the straightening angle (clockwise in this flipped view),
        // then source pixels, then draw the piece right side up.
        ctx.translateBy(x: frame.minX + frameCenter.x * v, y: frame.minY + frameCenter.y * v)
        ctx.rotate(by: theta)
        ctx.scaleBy(x: v / k, y: v / k)
        ctx.translateBy(x: box.minX - turnedCenter.x * k, y: box.maxY - turnedCenter.y * k)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(piece, in: CGRect(origin: .zero, size: box.size))
        ctx.restoreGState()
    }

    private func drawGrid(_ frame: CGRect, _ ctx: CGContext) {
        let visible = imageArea.intersection(frame)
        let step = max(40, min(90, min(frame.width, frame.height) / 8))
        let path = CGMutablePath()
        var x = frame.minX + (((visible.minX - frame.minX) / step).rounded(.up)) * step
        while x < visible.maxX {
            path.move(to: CGPoint(x: x, y: visible.minY))
            path.addLine(to: CGPoint(x: x, y: visible.maxY))
            x += step
        }
        var y = frame.minY + (((visible.minY - frame.minY) / step).rounded(.up)) * step
        while y < visible.maxY {
            path.move(to: CGPoint(x: visible.minX, y: y))
            path.addLine(to: CGPoint(x: visible.maxX, y: y))
            y += step
        }
        ctx.saveGState()
        ctx.clip(to: visible)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawLevelLine(_ line: (from: CGPoint, to: CGPoint), _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: line.from)
        ctx.addLine(to: line.to)
        ctx.strokePath()
        ctx.setFillColor(NSColor.systemYellow.cgColor)
        for p in [line.from, line.to] { ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }
        ctx.restoreGState()
    }

    private func drawSelection(_ sel: CGRect, frame: CGRect, _ ctx: CGContext) {
        let r = viewRect(sel, in: frame)
        let visible = imageArea.intersection(frame)

        ctx.saveGState()
        ctx.clip(to: visible)
        let shade = CGMutablePath()
        shade.addRect(visible)
        shade.addRect(r)
        ctx.addPath(shade)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fillPath(using: .evenOdd)
        if drag != nil {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            for k in 1...2 {
                let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
                ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
                ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        ctx.setFillColor(NSColor.white.cgColor)
        for x in [r.minX, r.midX, r.maxX] {
            for y in [r.minY, r.midY, r.maxY] where !(x == r.midX && y == r.midY) {
                ctx.fill(CGRect(x: x - handleSize / 2, y: y - handleSize / 2, width: handleSize, height: handleSize))
            }
        }
        ctx.restoreGState()

        let label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let above = r.minY - 30
        Pill.draw(label, at: CGPoint(x: max(r.minX, margin), y: above >= 0 ? above : max(r.minY, 0) + 8))
    }

    /// Stars and "saved" marks on the photo's top-right corner.
    private func drawBadges(on visible: CGRect) {
        var right = visible.maxX - 10
        let top = visible.minY + 10
        if savedCount > 0 {
            let text = savedCount == 1 ? "✓ Saved" : "✓ Saved ×\(savedCount)"
            right = Pill.draw(text, at: CGPoint(x: right - Pill.size(text).width, y: top),
                              fill: NSColor(red: 0.16, green: 0.55, blue: 0.27, alpha: 0.92)).minX - 8
        }
        if rating > 0 {
            let text = String(repeating: "★", count: rating)
            Pill.draw(text, at: CGPoint(x: right - Pill.size(text).width, y: top), color: .systemYellow)
        }
    }
}

private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    max(low, min(value, max(low, high)))
}
