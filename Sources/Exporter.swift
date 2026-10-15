import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case unreadable
    case jpegtranMissing
    case jpegtranFailed(String)
    case encodeFailed
    case malformedJPEG
    case noOrientationTag

    var errorDescription: String? {
        switch self {
        case .unreadable: return "the photo couldn't be read"
        case .jpegtranMissing: return "original-quality crops need jpegtran (brew install jpeg-turbo)"
        case .jpegtranFailed(let message): return "jpegtran failed: \(message)"
        case .encodeFailed: return "the JPEG couldn't be written"
        case .malformedJPEG: return "the JPEG's structure wasn't recognised"
        case .noOrientationTag: return "this photo has no orientation tag to rotate losslessly — switch to High quality"
        }
    }
}

/// Writes crops and copies on one background queue, so a burst of saves never races for a file name.
///
/// Originals are only ever read. Every file is written through `writeNew`, which refuses to replace an
/// existing file, so nothing — on the card or in the save folder — can be overwritten or deleted.
final class Exporter {
    static let jpegQuality = 0.95

    static let jpegtran: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("jpegtran") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    private let queue = DispatchQueue(label: "photocrop.export", qos: .userInitiated)

    /// `rect` is in crop-frame pixels (see `PhotoInfo.size`). Calls `completion` on the main thread.
    func saveCrop(of source: URL, info: PhotoInfo, rect: CGRect, quality: QualityMode, to folder: URL,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let result = Result<URL, Error> {
                if info.angle != 0 {
                    return try Self.renderStraightened(source, info: info, rect: rect, name: Self.cropName(source),
                                                       quality: quality == .original ? 1 : Self.jpegQuality, to: folder)
                }
                switch quality {
                case .high: return try Self.cropReencoded(source, info: info, rect: rect, to: folder)
                case .original: return try Self.cropLossless(source, info: info, rect: rect, to: folder)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func saveFull(_ source: URL, info: PhotoInfo, quality: QualityMode, to folder: URL,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let result = Result<URL, Error> {
                guard info.angle == 0 else {
                    let name = source.deletingPathExtension().lastPathComponent + "_straight"
                    return try Self.renderStraightened(source, info: info, rect: CGRect(origin: .zero, size: info.size),
                                                       name: name, quality: quality == .original ? 1 : Self.jpegQuality, to: folder)
                }
                return try Self.copyOriginal(source, info: info, to: folder)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// An exact copy; if rotated by quarter turns, only the orientation tag differs.
    static func copyOriginal(_ source: URL, info: PhotoInfo, to folder: URL) throws -> URL {
        var data = try Data(contentsOf: source)
        if info.quarterTurns != 0 { data = try JPEGMarkers.setOrientation(data, to: info.orientation) }
        let out = try writeNew(data, in: folder, name: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
        stampCaptureDate(out, info.captureDate)
        return out
    }

    /// Decodes the full photo, crops it and encodes a new JPEG, keeping the metadata.
    static func cropReencoded(_ source: URL, info: PhotoInfo, rect: CGRect, to folder: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let cropped = full.cropping(to: info.rawRect(fromDisplayRect: rect))
        else { throw ExportError.unreadable }
        // The crop is taken from the stored pixels, and the orientation tag says how to show them.
        let data = try encodeJPEG(cropped, metadata: metadata(of: src, image: cropped, orientation: info.orientation),
                                  quality: jpegQuality)
        let out = try writeNew(data, in: folder, name: cropName(source), ext: "jpg")
        stampCaptureDate(out, info.captureDate)
        return out
    }

    /// Crops the compressed data directly with jpegtran, so no pixel is re-encoded. JPEG can only be cut
    /// on its block grid (16×8 px for Sony JPEGs), so up to two edges may move outward by a few pixels.
    /// Quarter turns are applied by rewriting the orientation tag, which is lossless too.
    static func cropLossless(_ source: URL, info: PhotoInfo, rect: CGRect, to folder: URL) throws -> URL {
        guard let jpegtran else { throw ExportError.jpegtranMissing }
        let raw = info.rawRect(fromDisplayRect: rect)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photocrop-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }  // our own temp file, never a photo

        let process = Process()
        process.executableURL = jpegtran
        process.arguments = ["-copy", "all",
                             "-crop", "\(Int(raw.width))x\(Int(raw.height))+\(Int(raw.minX))+\(Int(raw.minY))",
                             "-outfile", temp.path, source.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // Exit status 2 means "finished with warnings"; the output is still complete.
        guard process.terminationStatus == 0 || process.terminationStatus == 2,
              let cropped = try? Data(contentsOf: temp), !cropped.isEmpty
        else { throw ExportError.jpegtranFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var result = try JPEGMarkers.tidyAfterCrop(cropped)
        if info.quarterTurns != 0 { result = try JPEGMarkers.setOrientation(result, to: info.orientation) }
        let out = try writeNew(result, in: folder, name: cropName(source), ext: "jpg")
        stampCaptureDate(out, info.captureDate)
        return out
    }

    /// Straightening by an arbitrary angle resamples every pixel, so this renders a new image (upright,
    /// orientation 1). `rect` is in the straightened frame.
    static func renderStraightened(_ source: URL, info: PhotoInfo, rect: CGRect, name: String, quality: Double,
                                   to folder: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let oriented = PhotoDecoder.fullResolution(of: source)
        else { throw ExportError.unreadable }
        let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
        let space = oriented.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.encodeFailed }

        // In y-down coordinates: crop origin → frame centre, turn clockwise by quarter turns + angle,
        // then the EXIF-oriented photo centred on it.
        let frame = info.size
        let photo = CGSize(width: oriented.width, height: oriented.height)
        let alpha = (Double(info.quarterTurns) * 90 + info.angle) * .pi / 180
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: frame.width / 2 - rect.minX, y: frame.height / 2 - rect.minY)
        ctx.rotate(by: CGFloat(alpha))
        ctx.translateBy(x: -photo.width / 2, y: photo.height / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(oriented, in: CGRect(origin: .zero, size: photo))
        guard let image = ctx.makeImage() else { throw ExportError.encodeFailed }

        let data = try encodeJPEG(image, metadata: metadata(of: src, image: image, orientation: .up), quality: quality)
        let out = try writeNew(data, in: folder, name: name, ext: "jpg")
        stampCaptureDate(out, info.captureDate)
        return out
    }

    /// The source's metadata with the pixel size and orientation updated for `image`.
    private static func metadata(of source: CGImageSource, image: CGImage,
                                 orientation: CGImagePropertyOrientation) -> CGMutableImageMetadata {
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap(CGImageMetadataCreateMutableCopy)
            ?? CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
                                                     kCGImagePropertyExifPixelXDimension, image.width as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
                                                     kCGImagePropertyExifPixelYDimension, image.height as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFOrientation, orientation.rawValue as CFNumber)
        return metadata
    }

    private static func encodeJPEG(_ image: CGImage, metadata: CGImageMetadata, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.encodeFailed }
        CGImageDestinationAddImageAndMetadata(dest, image, metadata,
                                              [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed }
        return data as Data
    }

    /// Writes to a new file named `name.ext`, or `name-2.ext`, `name-3.ext`… if taken. Never replaces a file.
    private static func writeNew(_ data: Data, in folder: URL, name: String, ext: String) throws -> URL {
        let out = uniqueURL(in: folder, name: name, ext: ext)
        try data.write(to: out, options: .withoutOverwriting)
        return out
    }

    static func cropName(_ source: URL) -> String {
        source.deletingPathExtension().lastPathComponent + "_crop"
    }

    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// Sets the file's creation date to when the photo was taken, so "Date Created" sorts by shooting time.
    private static func stampCaptureDate(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }
}

/// Byte-level edits to JPEG headers. Image data is never touched.
enum JPEGMarkers {
    /// jpegtran copies the camera's metadata verbatim, but some of it describes the uncropped photo.
    /// This drops the MPF index (it points at a preview image jpegtran didn't copy), unlinks the EXIF
    /// thumbnail (it still shows the whole frame), updates EXIF PixelXDimension/PixelYDimension, and drops
    /// the JFIF header jpegtran adds so the file starts with EXIF like the camera's own.
    static func tidyAfterCrop(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let (segments, scanStart) = try headerSegments(bytes)
        var width = 0, height = 0
        for range in segments where isStartOfFrame(bytes[range.lowerBound + 1]) && range.count >= 9 {
            height = Int(bytes[range.lowerBound + 5]) << 8 | Int(bytes[range.lowerBound + 6])
            width = Int(bytes[range.lowerBound + 7]) << 8 | Int(bytes[range.lowerBound + 8])
        }

        let hasExif = segments.contains { isApp(bytes, $0, 0xE1, "Exif\0\0") }
        var out = Data([0xFF, 0xD8])
        for range in segments {
            if isApp(bytes, range, 0xE2, "MPF\0") { continue }
            if hasExif, isApp(bytes, range, 0xE0, "JFIF\0") { continue }
            var segment = Array(bytes[range])
            if isApp(bytes, range, 0xE1, "Exif\0\0"), width > 0 {
                patchExif(&segment, width: width, height: height)
            }
            out.append(contentsOf: segment)
        }
        out.append(contentsOf: bytes[scanStart...])
        return out
    }

    /// Rewrites the orientation tag in place (EXIF, and XMP if it has one). Every other byte, including
    /// anything after the image data, stays identical.
    static func setOrientation(_ data: Data, to orientation: CGImagePropertyOrientation) throws -> Data {
        var bytes = [UInt8](data)
        let digit = UInt8(ascii: "0") + UInt8(orientation.rawValue)
        var found = false
        for range in try headerSegments(bytes).segments {
            if isApp(bytes, range, 0xE1, "Exif\0\0"), var tiff = TIFF(Array(bytes[range]), base: 10),
               tiff.setOrientation(Int(orientation.rawValue)) {
                bytes.replaceSubrange(range, with: tiff.bytes)
                found = true
            } else if isApp(bytes, range, 0xE1, "http://ns.adobe.com/xap/1.0/\0") {
                for key in ["tiff:Orientation=\"", "<tiff:Orientation>"] {
                    for i in positions(after: Array(key.utf8), in: bytes, within: range)
                    where (UInt8(ascii: "1")...UInt8(ascii: "8")).contains(bytes[i]) {
                        bytes[i] = digit
                    }
                }
            }
        }
        guard found else { throw ExportError.noOrientationTag }
        return Data(bytes)
    }

    /// The preview image a camera stores after the main image (located via the MPF index in the header),
    /// read without touching the rest of the file.
    static func embeddedPreview(of url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 256 * 1024) else { return nil }
        let bytes = [UInt8](head)
        guard let segments = try? headerSegments(bytes).segments else { return nil }
        for range in segments where isApp(bytes, range, 0xE2, "MPF\0") {
            // MPF is TIFF-structured; its offsets count from the byte after "MPF\0".
            guard let tiff = TIFF(Array(bytes[range]), base: 8), let ifd = tiff.u32(4),
                  let entry = tiff.entry(0xB002, in: ifd), let length = tiff.u32(entry + 4), let list = tiff.u32(entry + 8)
            else { continue }
            // Entry 0 is the main image; the next is the preview.
            for n in 1..<max(1, length / 16) {
                guard let size = tiff.u32(list + 16 * n + 4), let offset = tiff.u32(list + 16 * n + 8), size > 0, offset > 0
                else { continue }
                try? file.seek(toOffset: UInt64(range.lowerBound + 8 + offset))
                if let data = try? file.read(upToCount: size), data.count == size, data.starts(with: [0xFF, 0xD8]) {
                    return data
                }
            }
        }
        return nil
    }

    /// Byte ranges of the header segments, and where the image data starts.
    private static func headerSegments(_ bytes: [UInt8]) throws -> (segments: [Range<Int>], scanStart: Int) {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw ExportError.malformedJPEG }
        var segments: [Range<Int>] = []
        var i = 2
        while true {
            guard i + 4 <= bytes.count, bytes[i] == 0xFF else { throw ExportError.malformedJPEG }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }         // fill byte
            if marker == 0xDA { return (segments, i) }     // start of scan: the rest is image data
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let end = i + 2 + length
            guard length >= 2, end <= bytes.count else { throw ExportError.malformedJPEG }
            segments.append(i..<end)
            i = end
        }
    }

    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].contains(marker)
    }

    private static func isApp(_ bytes: [UInt8], _ range: Range<Int>, _ marker: UInt8, _ signature: String) -> Bool {
        let sig = Array(signature.utf8)
        let start = range.lowerBound + 4
        return bytes[range.lowerBound + 1] == marker && range.count >= 4 + sig.count
            && Array(bytes[start..<start + sig.count]) == sig
    }

    /// Indexes just past each occurrence of `needle` inside `range`.
    private static func positions(after needle: [UInt8], in bytes: [UInt8], within range: Range<Int>) -> [Int] {
        guard range.count >= needle.count else { return [] }
        return (range.lowerBound...(range.upperBound - needle.count))
            .filter { bytes[$0] == needle[0] && Array(bytes[$0..<$0 + needle.count]) == needle }
            .map { $0 + needle.count }
            .filter { $0 < range.upperBound }
    }

    /// Edits values in place; nothing changes size, so every other offset in the block stays valid.
    private static func patchExif(_ segment: inout [UInt8], width: Int, height: Int) {
        guard var tiff = TIFF(segment, base: 10), let ifd0 = tiff.u32(4), let count = tiff.u16(ifd0) else { return }
        tiff.set32(ifd0 + 2 + 12 * count, 0)  // next-IFD link; IFD1 holds the thumbnail
        if let exifEntry = tiff.entry(0x8769, in: ifd0), let exif = tiff.u32(exifEntry + 8) {
            for (tag, value) in [(0xA002, width), (0xA003, height)] {
                guard let entry = tiff.entry(tag, in: exif), let type = tiff.u16(entry + 2) else { continue }
                if type == 3, value <= 0xFFFF { tiff.set16(entry + 8, value) }
                if type == 4 { tiff.set32(entry + 8, value) }
            }
        }
        segment = tiff.bytes
    }

    /// Minimal reader/writer for the TIFF structure inside an EXIF block. Offsets are relative to `base`.
    private struct TIFF {
        var bytes: [UInt8]
        let base: Int
        let littleEndian: Bool

        init?(_ bytes: [UInt8], base: Int) {
            guard bytes.count >= base + 8 else { return nil }
            self.bytes = bytes
            self.base = base
            littleEndian = bytes[base] == 0x49  // "II"
        }

        /// Sets the IFD0 Orientation tag; false if the file doesn't have one.
        mutating func setOrientation(_ value: Int) -> Bool {
            guard let ifd0 = u32(4), let entry = entry(0x0112, in: ifd0), u16(entry + 2) == 3 else { return false }
            set16(entry + 8, value)
            return true
        }

        func u16(_ offset: Int) -> Int? { read(offset, 2) }
        func u32(_ offset: Int) -> Int? { read(offset, 4) }
        mutating func set16(_ offset: Int, _ value: Int) { write(offset, 2, value) }
        mutating func set32(_ offset: Int, _ value: Int) { write(offset, 4, value) }

        /// Offset of the 12-byte entry for `tag` in the IFD starting at `ifd`.
        func entry(_ tag: Int, in ifd: Int) -> Int? {
            guard let count = u16(ifd) else { return nil }
            return (0..<count).map { ifd + 2 + 12 * $0 }.first { u16($0) == tag }
        }

        private func read(_ offset: Int, _ size: Int) -> Int? {
            let p = base + offset
            guard offset >= 0, p + size <= bytes.count else { return nil }
            let slice = bytes[p..<p + size]
            let ordered = littleEndian ? Array(slice.reversed()) : Array(slice)
            return ordered.reduce(0) { $0 << 8 | Int($1) }
        }

        private mutating func write(_ offset: Int, _ size: Int, _ value: Int) {
            let p = base + offset
            guard offset >= 0, p + size <= bytes.count else { return }
            for k in 0..<size {
                let byte = UInt8(truncatingIfNeeded: value >> (8 * k))
                bytes[littleEndian ? p + k : p + size - 1 - k] = byte
            }
        }
    }
}
