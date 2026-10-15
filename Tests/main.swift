import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Self-test: ./build.sh --test <output dir> [real photo]
//  1. Every EXIF orientation × every in-app rotation × every save mode must produce exactly what the
//     viewer shows. The expected image comes from ImageIO decoding a file tagged with the target
//     orientation, so the app's own rotation code isn't checked against itself.
//  2. With a real photo: both crop modes plus rotated saves on a camera file (size, pixels, metadata, timing).
//  3. Renders the viewer UI to ui.png for a visual check.

_ = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory()).appendingPathComponent("photocrop-selftest")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var failures = 0

func check(_ ok: Bool, _ message: String) {
    print((ok ? "  ok    " : "  FAIL  ") + message)
    if !ok { failures += 1 }
}

func pixels(_ image: CGImage) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return buffer
}

/// Mean absolute difference per channel (0–255), or nil when sizes differ.
func difference(_ a: CGImage, _ b: CGImage) -> Double? {
    guard a.width == b.width, a.height == b.height else { return nil }
    let pa = pixels(a), pb = pixels(b)
    var total = 0
    for i in 0..<pa.count where i % 4 != 3 { total += abs(Int(pa[i]) - Int(pb[i])) }
    return Double(total) / Double(pa.count / 4 * 3)
}

func describe(_ diff: Double?) -> String { diff.map { String(format: "diff %.2f", $0) } ?? "SIZE MISMATCH" }

func folder(_ name: String) -> URL {
    let url = out.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func rawImage(_ url: URL) -> CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)! }

func properties(_ url: URL) -> [String: Any] {
    CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [String: Any]
}

/// Whether IFD0 links to an IFD1 (the EXIF thumbnail).
func hasExifThumbnail(_ url: URL) -> Bool {
    let d = [UInt8](try! Data(contentsOf: url).prefix(200_000))
    guard let start = (0..<d.count - 6).first(where: { d[$0..<$0 + 6] == [0x45, 0x78, 0x69, 0x66, 0, 0] }) else { return false }
    let t = start + 6, le = d[t] == 0x49
    func u(_ o: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | Int(d[t + o + $1]) << (8 * (le ? $1 : n - 1 - $1)) } }
    let ifd0 = u(4, 4)
    return u(ifd0 + 2 + 12 * u(ifd0, 2), 4) != 0
}

/// Decodes with libjpeg's djpeg without chroma smoothing, so each block decodes on its own and a lossless
/// crop must match the source byte for byte. (ImageIO decodes big and small JPEGs slightly differently.)
func djpeg(_ url: URL) -> (width: Int, height: Int, rgb: [UInt8])? {
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/djpeg") else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/djpeg")
    process.arguments = ["-nosmooth", "-dct", "int", "-ppm", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    let data = [UInt8](pipe.fileHandleForReading.readDataToEndOfFile())
    process.waitUntilExit()
    // "P6\n<w> <h>\n255\n" then RGB bytes
    var lines: [String] = [], i = 0
    while lines.count < 3 {
        let end = data[i...].firstIndex(of: 0x0A)!
        lines.append(String(decoding: data[i..<end], as: UTF8.self))
        i = end + 1
    }
    let size = lines[1].split(separator: " ").map { Int($0)! }
    return (size[0], size[1], Array(data[i...]))
}

func identicalRegion(_ crop: URL, of source: (width: Int, height: Int, rgb: [UInt8]), at origin: CGPoint) -> Bool {
    guard let c = djpeg(crop) else { return false }
    let x = Int(origin.x), y = Int(origin.y)
    return (0..<c.height).allSatisfy { r in
        let s = ((y + r) * source.width + x) * 3
        return source.rgb[s..<s + c.width * 3].elementsEqual(c.rgb[r * c.width * 3..<(r + 1) * c.width * 3])
    }
}

typealias Save = (URL, PhotoInfo, CGRect, URL) throws -> URL
let saves: [(String, Save)] = [
    ("high", Exporter.cropReencoded),
    ("original", Exporter.cropLossless),
    ("whole", { source, info, _, dir in try Exporter.copyOriginal(source, info: info, to: dir) }),
]

// MARK: 1. Orientations × rotations

print("Orientation and rotation (synthetic 640×480 gradients)")
let synthetic: CGImage = {
    let w = 640, h = 480
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
        for x in 0..<w {
            let p = (y * w + x) * 4
            data[p] = UInt8(x * 255 / w)
            data[p + 1] = UInt8(y * 255 / h)
            data[p + 2] = UInt8(255 - (x + y) * 255 / (w + h))
        }
    }
    return ctx.makeImage()!
}()

func writeSynthetic(orientation: CGImagePropertyOrientation) -> URL {
    let url = out.appendingPathComponent("synthetic-o\(orientation.rawValue).jpg")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, synthetic, [
        kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImagePropertyOrientation: orientation.rawValue,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:06:17 10:20:30"],
    ] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return url
}

var rotationResults: [String] = []
for o in 1...8 {
    let orientation = CGImagePropertyOrientation(rawValue: UInt32(o))!
    let source = writeSynthetic(orientation: orientation)
    let base = PhotoDecoder.preview(of: source, maxPixelSize: 4000)!
    for turns in 0...3 {
        let photo = base.rotated(turns)
        let truth = PhotoDecoder.fullResolution(of: writeSynthetic(orientation: orientation.rotatedClockwise(turns)))!
        let shown = PhotoDecoder.rotate(PhotoDecoder.fullResolution(of: source)!, quarterTurns: turns)!
        var line = "o\(o)+\(turns * 90)°: preview \(describe(difference(photo.preview, truth)))"
        var ok = (difference(photo.preview, truth) ?? 99) < 1 && (difference(shown, truth) ?? 99) < 1
        let rect = CGRect(x: 32, y: 48, width: 160, height: 96)  // on the 16-px grid, so lossless is exact too
        for (mode, save) in saves {
            let file = try! save(source, photo.info, rect, folder("o\(o)-r\(turns)-\(mode)"))
            let expected = mode == "whole" ? truth : truth.cropping(to: rect)!
            let diff = difference(PhotoDecoder.fullResolution(of: file)!, expected)
            ok = ok && (diff ?? 99) < 3
            line += ", \(mode) \(describe(diff))"
        }
        check(ok, line)
    }
}

// MARK: Straightening

print("\nStraightening (synthetic): output pixels vs ImageIO's decode of the original")
for o in [1, 3, 6, 8] {
    let source = writeSynthetic(orientation: CGImagePropertyOrientation(rawValue: UInt32(o))!)
    let base = PhotoDecoder.preview(of: source, maxPixelSize: 4000)!
    let oriented = PhotoDecoder.fullResolution(of: source)!  // EXIF orientation applied by ImageIO
    let orientedPixels = pixels(oriented)
    for turns in [0, 1] {
        for angle in [7.5, -12.0] {
            var photo = base.rotated(turns)
            photo.info.angle = angle
            let frame = photo.info.size
            let crop = CGRect(x: frame.width * 0.1, y: frame.height * 0.15, width: frame.width * 0.6, height: frame.height * 0.5)
            for (name, rect) in [("crop", crop), ("whole", CGRect(origin: .zero, size: frame))] {
                let file = try! Exporter.renderStraightened(source, info: photo.info, rect: rect, name: "s", quality: 1,
                                                            to: folder("straight-o\(o)-r\(turns)-a\(angle)-\(name)"))
                let out = rawImage(file)
                let outPixels = pixels(out)
                let alpha = (Double(turns) * 90 + angle) * .pi / 180
                var total = 0.0, samples = 0, outside = 0
                for sy in stride(from: 0.005, through: 0.995, by: 0.0495) {
                    for sx in stride(from: 0.005, through: 0.995, by: 0.0495) {
                        let ox = Int(sx * Double(out.width)), oy = Int(sy * Double(out.height))
                        // Output pixel → frame → EXIF-oriented photo, by the definition of straightening.
                        let dx = rect.minX + CGFloat(ox) + 0.5 - frame.width / 2
                        let dy = rect.minY + CGFloat(oy) + 0.5 - frame.height / 2
                        let px = dx * cos(-alpha) - dy * sin(-alpha) + CGFloat(oriented.width) / 2
                        let py = dx * sin(-alpha) + dy * cos(-alpha) + CGFloat(oriented.height) / 2
                        guard px >= 0, py >= 0, px < CGFloat(oriented.width), py < CGFloat(oriented.height) else {
                            outside += 1
                            continue
                        }
                        let i = (oy * out.width + ox) * 4, j = (Int(py) * oriented.width + Int(px)) * 4
                        for c in 0..<3 { total += abs(Double(outPixels[i + c]) - Double(orientedPixels[j + c])) }
                        samples += 3
                    }
                }
                let diff = total / Double(max(samples, 1))
                check(diff < 3 && outside == 0,
                      "o\(o)+\(turns * 90)°\(angle > 0 ? "+" : "")\(angle)° \(name): \(out.width)×\(out.height), diff \(String(format: "%.2f", diff)), \(outside) samples off the photo")
            }
        }
    }
}

// MARK: Nothing is ever overwritten

print("\nSaving never overwrites")
do {
    let source = writeSynthetic(orientation: .up)
    let info = PhotoDecoder.preview(of: source, maxPixelSize: 100)!.info
    let before = try! Data(contentsOf: source)
    let dir = folder("no-overwrite")
    let first = try! Exporter.cropReencoded(source, info: info, rect: CGRect(x: 0, y: 0, width: 100, height: 100), to: dir)
    let firstBytes = try! Data(contentsOf: first)
    let second = try! Exporter.cropLossless(source, info: info, rect: CGRect(x: 0, y: 0, width: 200, height: 100), to: dir)
    let third = try! Exporter.cropReencoded(source, info: info, rect: CGRect(x: 0, y: 0, width: 300, height: 100), to: dir)
    check([first, second, third].map(\.lastPathComponent) == ["synthetic-o1_crop.jpg", "synthetic-o1_crop-2.jpg", "synthetic-o1_crop-3.jpg"],
          "repeated saves get new names: \([first, second, third].map(\.lastPathComponent))")
    check(try! Data(contentsOf: first) == firstBytes, "earlier save left untouched")
    // Saving into the originals' own folder must add a copy beside the original, not replace it.
    let copy = try! Exporter.copyOriginal(source, info: info, to: source.deletingLastPathComponent())
    check(copy.lastPathComponent == "synthetic-o1-2.jpg" && (try! Data(contentsOf: source)) == before,
          "saving next to the original adds \(copy.lastPathComponent); original unchanged")
}

// MARK: Trash

print("\nMove to Trash and put back")
do {
    let photo = folder("trash").appendingPathComponent("DSC09999.JPG")
    try! FileManager.default.copyItem(at: writeSynthetic(orientation: .up), to: photo)
    let before = try! Data(contentsOf: photo)
    let inTrash = try! PhotoLibrary.moveToTrash(photo)
    check(!FileManager.default.fileExists(atPath: photo.path) && inTrash.path.contains("/.Trash"),
          "moved to the Trash: \(inTrash.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
    check((try? Data(contentsOf: inTrash)) == before, "intact in the Trash")
    try! PhotoLibrary.restore(inTrash, to: photo)
    check((try? Data(contentsOf: photo)) == before && !FileManager.default.fileExists(atPath: inTrash.path), "put back unchanged")
    try! FileManager.default.copyItem(at: photo, to: inTrash)
    check((try? PhotoLibrary.restore(inTrash, to: photo)) == nil && (try? Data(contentsOf: photo)) == before,
          "putting back never replaces a file that has the name now")
    try? FileManager.default.removeItem(at: inTrash)  // the test's own copy in the Trash
}

// Clockwise really is clockwise: the top-left corner must end up top-right.
let turned = pixels(PhotoDecoder.rotate(synthetic, quarterTurns: 1)!)
let topRight = (synthetic.height - 1) * 4
check(turned[topRight] < 5 && turned[topRight + 1] < 5 && turned[topRight + 2] > 250, "R turns the photo clockwise")

// MARK: 2. Real photo

if args.count > 2 {
    let source = URL(fileURLWithPath: args[2])
    print("\nReal photo \(source.lastPathComponent)")
    var start = Date()
    let loaded = PhotoDecoder.preview(of: source, maxPixelSize: 3024)!
    print("  preview decode \(Int(Date().timeIntervalSince(start) * 1000)) ms, preview \(loaded.preview.width)×\(loaded.preview.height)")
    let info = loaded.info
    print("  stored \(info.rawWidth)×\(info.rawHeight), orientation \(info.orientation.rawValue), shown \(Int(info.size.width))×\(Int(info.size.height)), taken \(info.captureDate.map { "\($0)" } ?? "?")")
    let sourceHash = SHA256.hash(data: try! Data(contentsOf: source))
    let sourceRaw = rawImage(source)
    let sourceBlocks = djpeg(source)

    let rect = CGRect(x: 1001, y: 777, width: 3003, height: 2002)
    for turns in [0, 1] {
        let photo = loaded.rotated(turns)
        for (mode, save) in saves {
            if turns == 0 && mode == "whole" { continue }
            start = Date()
            let file = try! save(source, photo.info, rect, folder("real-r\(turns)-\(mode)"))
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let props = properties(file)
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let shown = PhotoDecoder.preview(of: file, maxPixelSize: 100)!.info.size
            let w = Int(shown.width), h = Int(shown.height)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            let tag = "\(mode)\(turns > 0 ? " rotated" : "")"
            print("  \(tag): \(file.lastPathComponent) shown \(w)×\(h), \(bytes / 1024) KB, \(ms) ms")

            check((props[kCGImagePropertyOrientation as String] as? Int) == Int(photo.info.orientation.rawValue),
                  "\(tag): orientation tag \(props[kCGImagePropertyOrientation as String] ?? "-") = \(photo.info.orientation.rawValue)")
            check(tiff[kCGImagePropertyTIFFModel as String] != nil && exif[kCGImagePropertyExifLensModel as String] != nil
                  && exif[kCGImagePropertyExifDateTimeOriginal as String] != nil, "\(tag): camera, lens and capture time kept")
            let created = try? FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date
            check(created.map { abs($0.timeIntervalSince(info.captureDate ?? .distantPast)) < 1 } ?? false, "\(tag): file date = capture time")

            if mode == "whole" {
                let a = [UInt8](try! Data(contentsOf: source)), b = [UInt8](try! Data(contentsOf: file))
                let changed = a.count == b.count ? zip(a, b).filter { $0 != $1 }.count : -1
                check(changed == 1, "\(tag): identical to the original except the orientation byte (\(changed) byte(s) differ)")
                continue
            }

            let raw = photo.info.rawRect(fromDisplayRect: rect)
            let expectedRaw: CGRect
            if mode == "high" {
                check(w == 3003 && h == 2002, "\(tag): exact size")
                expectedRaw = raw
            } else {
                check(w >= 3003 && h >= 2002 && w - 3003 < 16 && h - 2002 < 16, "\(tag): grows less than one block (+\(w - 3003), +\(h - 2002) px)")
                // Sony JPEGs are 4:2:2, so jpegtran snaps the stored top-left corner to a 16×8 grid.
                let x = floor(raw.minX / 16) * 16, y = floor(raw.minY / 8) * 8
                expectedRaw = CGRect(x: x, y: y, width: raw.maxX - x, height: raw.maxY - y)
            }
            if mode == "original", let sourceBlocks {
                check(identicalRegion(file, of: sourceBlocks, at: expectedRaw.origin), "\(tag): bit-identical to the source region")
            } else {
                let diff = difference(rawImage(file), sourceRaw.cropping(to: expectedRaw)!)
                // A wrong region differs by 20+; re-encoding a noisy high-ISO frame costs up to ~3.
                check((diff ?? 99) < 4, "\(tag): pixels match the source (\(describe(diff)))")
            }
            check(exif[kCGImagePropertyExifPixelXDimension as String] as? Int == rawImage(file).width, "\(tag): EXIF pixel size updated")
            check(!hasExifThumbnail(file), "\(tag): no stale embedded thumbnail")
            check(try! Data(contentsOf: file).prefix(200_000).range(of: Data("MPF\0".utf8)) == nil, "\(tag): no stale MPF preview index")
        }
    }

    // Straightened whole photo, for a visual comparison with the UI render below.
    var straight = loaded
    straight.info.angle = 8
    start = Date()
    let straightFile = try! Exporter.renderStraightened(source, info: straight.info, rect: CGRect(origin: .zero, size: straight.info.size),
                                                        name: "straight", quality: 1, to: folder("real-straight"))
    print("  straightened whole photo +8°: \(Int(straight.info.size.width))×\(Int(straight.info.size.height)), \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    let thumb = CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithURL(straightFile as CFURL, nil)!, 0,
        [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 900,
         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
    let thumbDest = CGImageDestinationCreateWithURL(out.appendingPathComponent("straight-preview.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(thumbDest, thumb, nil)
    CGImageDestinationFinalize(thumbDest)

    check(SHA256.hash(data: try! Data(contentsOf: source)) == sourceHash, "card photo \(source.lastPathComponent) is byte-for-byte unchanged after all saves")

    // MARK: 3. Grid thumbnails
    let card = PhotoLibrary.photos(in: source.deletingLastPathComponent())
    start = Date()
    let sample = Array(card.suffix(30))
    var worst = 0.0
    for url in sample {
        let thumb = PhotoDecoder.thumbnail(of: url, maxPixelSize: ThumbnailLoader.maxPixelSize)!
        let reference = CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ThumbnailLoader.maxPixelSize] as CFDictionary)!
        worst = max(worst, difference(thumb, reference) ?? 999)
    }
    print("  embedded-preview thumbnails: \(Int(Date().timeIntervalSince(start) * 1000 / Double(sample.count))) ms each (incl. reference decode)")
    check(worst < 8, "thumbnails match the photo, same size and orientation (worst diff \(String(format: "%.2f", worst)))")
    start = Date()
    for url in sample { _ = PhotoDecoder.thumbnail(of: url, maxPixelSize: ThumbnailLoader.maxPixelSize) }
    print("  thumbnail alone: \(Int(Date().timeIntervalSince(start) * 1000 / Double(sample.count))) ms each → \(card.count) photos ≈ \(Int(Date().timeIntervalSince(start) / Double(sample.count) * Double(card.count) / 3)) s with 3 in parallel")

    // MARK: 4. UI renders
    func save(_ view: NSView, _ name: String) {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        print("  rendered \(name)")
    }
    func photoView(_ configure: (PhotoView) -> Void) -> PhotoView {
        let view = PhotoView(frame: CGRect(x: 0, y: 0, width: 1440, height: 844))
        view.setPhoto(loaded)
        view.rating = 4
        view.savedCount = 1
        configure(view)
        return view
    }
    save(photoView { view in
        view.ratio = 3.0 / 2.0
        view.setAngle(8)
        view.selection = CGRect(x: 800, y: 2600, width: 3900, height: 2600)
    }, "ui.png")
    // Zoom steps: gentle, landing on 100%, and Z at the maximum goes back to fit.
    let stepper = photoView { _ in }
    var percents = [stepper.zoomPercent]
    for _ in 0..<12 { stepper.zoomStepIn(at: nil); percents.append(stepper.zoomPercent) }
    let steps = zip(percents, percents.dropFirst()).prefix { $1 > $0 }.map { Double($1) / Double($0) }
    check(steps.allSatisfy { $0 > 1.2 && $0 < 1.6 } && percents.contains(100) && percents.contains(percents[0]) && percents.dropFirst().contains(percents[0]),
          "Z steps: \(percents.map { "\($0)%" }.joined(separator: " → "))")

    save(photoView { view in
        view.zoomIn()
        view.zoomIn()
        view.selection = CGRect(x: 2000, y: 3000, width: 1500, height: 1000)
    }, "ui-zoom.png")

    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1440, height: 844))
    let grid = GridView(frame: scroll.bounds)
    scroll.documentView = grid
    scroll.hasVerticalScroller = true
    grid.marks = { url in
        let n = card.firstIndex(of: url) ?? 0
        return GridView.Marks(rating: n % 7 == 0 ? 3 : (n % 5 == 0 ? 5 : 0), saved: n % 4 == 1, quarterTurns: n == 2 ? 1 : 0)
    }
    grid.photos = card
    grid.focusIndex = 6
    grid.relayout()
    save(scroll, "grid-loading.png")  // first draw queues the visible thumbnails
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, card.prefix(18).contains(where: { grid.thumbnails.thumbnail(for: $0) == nil }) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    save(scroll, "grid.png")

    for mode in [ViewMode.photo, .grid] {
        let bar = StatusBarView(frame: CGRect(x: 0, y: 0, width: 1440, height: StatusBarView.height))
        bar.hud = HUDInfo(mode: mode, name: source.lastPathComponent, position: "8 / \(card.count)", rating: 4, savedCount: 1,
                          rotation: "8°", ratio: "3:2", quality: "Original", destination: "Desktop")
        save(bar, "bar-\(mode.rawValue).png")
    }
}

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
