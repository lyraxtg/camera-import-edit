import AppKit

enum PhotoLibrary {
    /// JPEGs in `folder`, in camera order. A card root or DCIM folder is searched one level deep
    /// (100MSDCF, 101MSDCF, ...).
    static func photos(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let dcim = folder.appendingPathComponent("DCIM", isDirectory: true)
        let root = fm.fileExists(atPath: dcim.path) ? dcim : folder
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }
        var photos: [URL] = []
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                photos += inner.filter(isPhoto)
            } else if isPhoto(item) {
                photos.append(item)
            }
        }
        return photos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The first mounted volume that looks like a camera card.
    static func findCameraCard() -> URL? {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.first { volume in
            FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path)
                && !photos(in: volume).isEmpty
        }
    }

    /// Moves a photo to the Trash the way Finder does, so it can be put back. On a camera card macOS keeps
    /// it in the card's own hidden Trash folder, shown in the Mac's Trash while the card is connected.
    /// Returns where it went.
    static func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// Puts a trashed photo back. Fails rather than replacing a file that now has its name.
    static func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    private static func isPhoto(_ url: URL) -> Bool {
        // "._DSC0001.JPG" files are macOS metadata droppings, not photos.
        !url.lastPathComponent.hasPrefix(".") && ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }
}

enum QualityMode: String {
    /// Re-encoded JPEG with exact crop edges. macOS's encoder always uses 4:2:0 chroma below quality 1.0,
    /// so this loses some colour resolution against the camera's 4:2:2 files whatever the quality setting.
    case high
    /// Lossless jpegtran crop: bit-identical pixels at about the same file size. Edges snap outward
    /// to the JPEG block grid by a few pixels.
    case original

    var label: String {
        switch self {
        case .high: return "High (JPEG 95%)"
        case .original: return "Original (lossless)"
        }
    }

    var toggled: QualityMode { self == .high ? .original : .high }
}

struct AspectRatio {
    let width: Int
    let height: Int

    static let presets = [
        AspectRatio(width: 0, height: 0),
        AspectRatio(width: 3, height: 2),
        AspectRatio(width: 4, height: 3),
        AspectRatio(width: 1, height: 1),
        AspectRatio(width: 4, height: 5),
        AspectRatio(width: 16, height: 9),
    ]

    var isFree: Bool { width == 0 }

    /// Width divided by height, or nil for a free crop.
    func value(flipped: Bool) -> CGFloat? {
        if isFree { return nil }
        return flipped ? CGFloat(height) / CGFloat(width) : CGFloat(width) / CGFloat(height)
    }

    func label(flipped: Bool) -> String {
        if isFree { return "Free" }
        return flipped ? "\(height):\(width)" : "\(width):\(height)"
    }
}

final class Settings {
    private let defaults = UserDefaults.standard

    var destination: URL {
        get {
            defaults.string(forKey: "destination").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set {
            defaults.set(newValue.path, forKey: "destination")
            let others = recentDestinations.filter { $0.path != newValue.path }.map(\.path)
            defaults.set(Array(([newValue.path] + others).prefix(8)), forKey: "recentDestinations")
        }
    }

    /// Save folders used before, most recent first; the current one is included.
    var recentDestinations: [URL] {
        let paths = defaults.stringArray(forKey: "recentDestinations") ?? []
        let current = destination.path
        return ([current] + paths.filter { $0 != current }).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var quality: QualityMode {
        get { QualityMode(rawValue: defaults.string(forKey: "quality") ?? "") ?? (Exporter.jpegtran != nil ? .original : .high) }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    var ratioIndex: Int {
        get { min(max(defaults.integer(forKey: "ratioIndex"), 0), AspectRatio.presets.count - 1) }
        set { defaults.set(newValue, forKey: "ratioIndex") }
    }

    var ratioFlipped: Bool {
        get { defaults.bool(forKey: "ratioFlipped") }
        set { defaults.set(newValue, forKey: "ratioFlipped") }
    }

    var mode: ViewMode {
        get { ViewMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .photo }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var thumbnailSize: CGFloat {
        get { let size = defaults.double(forKey: "thumbnailSize"); return size > 0 ? CGFloat(size) : 200 }
        set { defaults.set(Double(newValue), forKey: "thumbnailSize") }
    }

    func lastPhoto(in folder: URL) -> String? {
        (defaults.dictionary(forKey: "lastPhoto") as? [String: String])?[folder.path]
    }

    func setLastPhoto(_ name: String, in folder: URL) {
        var all = (defaults.dictionary(forKey: "lastPhoto") as? [String: String]) ?? [:]
        all[folder.path] = name
        defaults.set(all, forKey: "lastPhoto")
    }
}

/// What the app remembers about card photos: which were saved (and where) and their star ratings.
/// Kept in Application Support; the photo files themselves are never modified. Photos are identified
/// by name, size and timestamp because camera file names repeat across cards.
final class PhotoRecords {
    private let savedFile: URL
    private let ratingsFile: URL
    private var saved: [String: [String]]
    private var ratings: [String: Int]
    private var keys: [URL: String] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedFile = dir.appendingPathComponent("saved.json")
        ratingsFile = dir.appendingPathComponent("ratings.json")
        saved = Self.load(savedFile) ?? [:]
        ratings = Self.load(ratingsFile) ?? [:]
    }

    func savedCount(for photo: URL) -> Int { saved[key(for: photo)]?.count ?? 0 }

    func recordSave(_ photo: URL, output: URL) {
        saved[key(for: photo), default: []].append(output.path)
        Self.store(saved, savedFile)
    }

    /// 0 means unrated.
    func rating(for photo: URL) -> Int { ratings[key(for: photo)] ?? 0 }

    func setRating(_ stars: Int, for photo: URL) {
        ratings[key(for: photo)] = stars == 0 ? nil : stars
        Self.store(ratings, ratingsFile)
    }

    private func key(for photo: URL) -> String {
        if let key = keys[photo] { return key }
        let values = try? photo.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let key = "\(photo.lastPathComponent)|\(values?.fileSize ?? 0)|\(stamp)"
        keys[photo] = key
        return key
    }

    private static func load<T: Decodable>(_ file: URL) -> T? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store<T: Encodable>(_ value: T, _ file: URL) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) }
    }
}
