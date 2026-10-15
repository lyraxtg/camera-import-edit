import AppKit
import ImageIO

/// Size, orientation and capture time of a photo, read from its header.
struct PhotoInfo {
    let rawWidth: Int
    let rawHeight: Int
    /// Orientation stored in the file's EXIF.
    let fileOrientation: CGImagePropertyOrientation
    let captureDate: Date?
    /// Extra clockwise quarter turns chosen in the app, 0–3.
    var quarterTurns = 0
    /// Straightening angle in degrees, clockwise, within ±45. Unlike quarter turns this resamples pixels.
    var angle: Double = 0

    /// How the stored pixels are shown: the file's own orientation plus the app's rotation.
    var orientation: CGImagePropertyOrientation { fileOrientation.rotatedClockwise(quarterTurns) }

    init?(source: CGImageSource) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        else { return nil }
        rawWidth = width
        rawHeight = height
        fileOrientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        captureDate = Self.parseExifDate(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                                         offset: exif?["OffsetTimeOriginal"] as? String)
    }

    /// Pixel size after the EXIF orientation and quarter turns, before straightening.
    var turnedSize: CGSize {
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left:
            return CGSize(width: rawHeight, height: rawWidth)
        default:
            return CGSize(width: rawWidth, height: rawHeight)
        }
    }

    /// Size of the frame you crop in. When straightened, it's the largest rect of the photo's own shape
    /// that fits inside the tilted photo, so there are never empty corners.
    var size: CGSize {
        let s = turnedSize
        guard angle != 0 else { return s }
        let a = CGFloat(abs(angle) * .pi / 180)
        let c = cos(a), sn = sin(a)
        let widthFit: CGFloat = s.width / (s.width * c + s.height * sn)
        let heightFit: CGFloat = s.height / (s.width * sn + s.height * c)
        let k = min(widthFit, heightFit)
        return CGSize(width: (s.width * k).rounded(.down), height: (s.height * k).rounded(.down))
    }

    /// Maps a rect in displayed pixels onto the stored (un-rotated) pixel grid, rounded to whole pixels.
    /// Only meaningful when not straightened.
    func rawRect(fromDisplayRect r: CGRect) -> CGRect {
        let a = rawPoint(CGPoint(x: r.minX.rounded(), y: r.minY.rounded()))
        let b = rawPoint(CGPoint(x: r.maxX.rounded(), y: r.maxY.rounded()))
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return rect.intersection(CGRect(x: 0, y: 0, width: rawWidth, height: rawHeight))
    }

    private func rawPoint(_ p: CGPoint) -> CGPoint {
        let w = CGFloat(rawWidth), h = CGFloat(rawHeight)
        switch orientation {
        case .up: return p
        case .upMirrored: return CGPoint(x: w - p.x, y: p.y)
        case .down: return CGPoint(x: w - p.x, y: h - p.y)
        case .downMirrored: return CGPoint(x: p.x, y: h - p.y)
        case .leftMirrored: return CGPoint(x: p.y, y: p.x)
        case .right: return CGPoint(x: p.y, y: h - p.x)
        case .rightMirrored: return CGPoint(x: w - p.y, y: h - p.x)
        case .left: return CGPoint(x: w - p.y, y: p.x)
        }
    }

    private static func parseExifDate(_ text: String?, offset: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        return formatter.date(from: text)
    }

    /// Parses an EXIF offset such as "+09:00".
    private static func timeZone(fromOffset text: String) -> TimeZone? {
        let parts = text.dropFirst().split(separator: ":")
        guard let sign = text.first, sign == "+" || sign == "-",
              let hours = parts.first.flatMap({ Int($0) }) else { return nil }
        let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}

extension CGImagePropertyOrientation {
    /// This orientation followed by `quarterTurns` clockwise quarter turns of the displayed image.
    func rotatedClockwise(_ quarterTurns: Int) -> CGImagePropertyOrientation {
        let cycles: [[CGImagePropertyOrientation]] = [[.up, .right, .down, .left],
                                                      [.upMirrored, .rightMirrored, .downMirrored, .leftMirrored]]
        guard let cycle = cycles.first(where: { $0.contains(self) }), let i = cycle.firstIndex(of: self) else { return self }
        return cycle[((i + quarterTurns) % 4 + 4) % 4]
    }

    /// Clockwise quarter turns that show stored pixels this way up; nil for mirrored orientations.
    var clockwiseTurns: Int? {
        [CGImagePropertyOrientation.up, .right, .down, .left].firstIndex(of: self)
    }
}

struct LoadedPhoto {
    var info: PhotoInfo
    /// Screen-sized, already rotated to its display orientation.
    let preview: CGImage

    /// The same photo turned `quarterTurns` (0–3) clockwise from how the file shows it.
    func rotated(_ quarterTurns: Int) -> LoadedPhoto {
        guard quarterTurns != info.quarterTurns,
              let image = PhotoDecoder.rotate(preview, quarterTurns: quarterTurns - info.quarterTurns) else { return self }
        var info = info
        info.quarterTurns = quarterTurns
        return LoadedPhoto(info: info, preview: image)
    }
}

enum PhotoDecoder {
    static func preview(of url: URL, maxPixelSize: Int) -> LoadedPhoto? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = PhotoInfo(source: source),
              let image = orientedImage(source, maxPixelSize: maxPixelSize)
        else { return nil }
        return LoadedPhoto(info: info, preview: image)
    }

    /// The whole photo at full resolution, rotated to its display orientation.
    static func fullResolution(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = PhotoInfo(source: source)
        else { return nil }
        return orientedImage(source, maxPixelSize: max(info.rawWidth, info.rawHeight))
    }

    /// A small version of the photo, oriented for display. Uses the preview the camera stores in the
    /// file when there is one (Sony: 1616×1080 after the main image), which is ~7× faster than
    /// decoding the full 53 MP photo.
    static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = PhotoInfo(source: source)
        else { return nil }
        if let data = JPEGMarkers.embeddedPreview(of: url),
           let preview = CGImageSourceCreateWithData(data as CFData, nil),
           let small = CGImageSourceCreateThumbnailAtIndex(preview, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
           ] as CFDictionary),
           let turns = info.fileOrientation.clockwiseTurns,
           // Some cameras letterbox the preview; only use it when it has the photo's shape.
           abs(CGFloat(small.width) / CGFloat(small.height) - CGFloat(info.rawWidth) / CGFloat(info.rawHeight)) < 0.02,
           let oriented = rotate(small, quarterTurns: turns) {
            return oriented
        }
        return orientedImage(source, maxPixelSize: maxPixelSize)
    }

    /// Turns an image clockwise by `quarterTurns` × 90°.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = (quarterTurns % 4 + 4) % 4
        if turns == 0 { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let size = turns == 2 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        // Core Graphics is y-up, so turning clockwise on screen is a negative angle here.
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    private static func orientedImage(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Decodes previews off the main thread and keeps the ones around the current photo,
/// so stepping through a card feels instant.
final class PhotoLoader {
    var maxPixelSize = 3000

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var cache: [URL: LoadedPhoto] = [:]
    private var pending: [URL: Operation] = [:]
    private var callbacks: [URL: [(LoadedPhoto?) -> Void]] = [:]

    func cached(_ url: URL) -> LoadedPhoto? { cache[url] }

    /// Calls `completion` on the main thread.
    func load(_ url: URL, priority: Operation.QueuePriority, completion: ((LoadedPhoto?) -> Void)? = nil) {
        if let hit = cache[url] {
            completion?(hit)
            return
        }
        if let completion { callbacks[url, default: []].append(completion) }
        if let op = pending[url] {
            if op.queuePriority.rawValue < priority.rawValue { op.queuePriority = priority }
            return
        }
        let size = maxPixelSize
        let op = BlockOperation {
            let photo = PhotoDecoder.preview(of: url, maxPixelSize: size)
            DispatchQueue.main.async { self.finish(url, photo) }
        }
        op.queuePriority = priority
        pending[url] = op
        queue.addOperation(op)
    }

    /// Drops cached previews and cancels queued decodes for everything not in `urls`.
    func keepOnly(_ urls: Set<URL>) {
        cache = cache.filter { urls.contains($0.key) }
        for (url, op) in pending where !urls.contains(url) {
            op.cancel()
            pending[url] = nil
            callbacks[url] = nil
        }
    }

    private func finish(_ url: URL, _ photo: LoadedPhoto?) {
        guard pending.removeValue(forKey: url) != nil else { return }
        if let photo { cache[url] = photo }
        callbacks.removeValue(forKey: url)?.forEach { $0(photo) }
    }
}
