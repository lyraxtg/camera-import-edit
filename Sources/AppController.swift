import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, PhotoViewDelegate, GridViewDelegate,
                           StatusBarDelegate {
    private var window: NSWindow!
    private let photoView = PhotoView()
    private let grid = GridView(frame: .zero)
    private let gridScroll = NSScrollView()
    private let statusBar = StatusBarView()
    private let toast = ToastView()
    private let loader = PhotoLoader()
    private let exporter = Exporter()
    private let settings = Settings()
    private let records = PhotoRecords()

    private var mode = ViewMode.photo
    private var folder: URL?
    private var photos: [URL] = []
    private var index = 0
    /// The photo in the photo view, with its rotation applied.
    private var current: LoadedPhoto?
    private var shownURL: URL?
    /// Showing the grid thumbnail while the sharper preview loads.
    private var placeholderFor: URL?
    /// Quarter turns and straightening angles per photo, for this session.
    private var rotations: [URL: Int] = [:]
    private var angles: [URL: Double] = [:]
    private var fullResolutionRequest: String?
    /// Photos moved to the Trash this session, newest last, for ⌘Z.
    private var trashed: [(original: URL, inTrash: URL)] = []

    private var currentURL: URL? { photos.indices.contains(index) ? photos[index] : nil }
    private var ratio: AspectRatio { AspectRatio.presets[settings.ratioIndex] }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        photoView.delegate = self
        photoView.ratio = ratio.value(flipped: settings.ratioFlipped)
        grid.delegate = self
        grid.thumbnailSize = settings.thumbnailSize
        grid.onThumbnailSizeChange = { [weak self] size in self?.settings.thumbnailSize = size }
        grid.marks = { [weak self] url in
            guard let self else { return GridView.Marks() }
            return GridView.Marks(rating: records.rating(for: url), saved: records.savedCount(for: url) > 0,
                                  quarterTurns: rotations[url] ?? 0)
        }
        statusBar.delegate = self

        let screen = NSScreen.main ?? NSScreen.screens.first
        let longSide = max(screen?.frame.width ?? 1512, screen?.frame.height ?? 982) * (screen?.backingScaleFactor ?? 2)
        loader.maxPixelSize = Int(min(max(longSide, 1600), 4000))

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        guard folder == nil else { return }  // already opened via Finder / `open`
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }) {
            open(URL(fileURLWithPath: arg))
        } else if let card = PhotoLibrary.findCameraCard() {
            open(card)
        } else {
            photoView.status = "Insert your camera card, or press ⌘O to open a folder of photos."
            setMode(.photo)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidResignKey(_ notification: Notification) {
        photoView.isPeeking = false  // the Space key-up would go to another app
    }

    private func buildWindow() {
        let frame = (NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 40, dy: 30)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PhotoCrop"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.09, alpha: 1)
        window.minSize = NSSize(width: 900, height: 500)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        // Photo view or grid on top, status bar along the bottom, messages floating over the top.
        let root = NSView()
        window.contentView = root
        let bar = StatusBarView.height
        let content = NSRect(x: 0, y: bar, width: root.bounds.width, height: root.bounds.height - bar)
        photoView.frame = content
        gridScroll.frame = content
        toast.frame = content
        for view in [photoView, gridScroll, toast] as [NSView] { view.autoresizingMask = [.width, .height] }
        statusBar.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: bar)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.backgroundColor = NSColor(white: 0.09, alpha: 1)
        gridScroll.documentView = grid
        for view in [photoView, gridScroll, statusBar, toast] as [NSView] { root.addSubview(view) }

        window.setFrameAutosaveName("PhotoCropMain")
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            return holder
        }

        let main = NSMenu()
        main.addItem(submenu("PhotoCrop", [
            item("Hide PhotoCrop", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit PhotoCrop", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("Open Folder…", #selector(openFolder(_:)), "o", target: self),
            item("Choose Save Folder…", #selector(chooseDestination(_:)), "d", target: self),
            .separator(),
            item("Move Photo to Trash", #selector(moveToTrash(_:)), "\u{8}", target: self),
            item("Show Photo in Finder", #selector(showPhotoInFinder(_:)), "", target: self),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo Move to Trash", #selector(undoMoveToTrash(_:)), "z", target: self),
            .separator(),
            item("Select Whole Photo", #selector(selectWholePhoto(_:)), "a", target: self),
        ]))
        main.addItem(submenu("View", [
            item("Grid / Photo  (G)", #selector(toggleMode(_:)), "", target: self),
            .separator(),
            item("Zoom In", #selector(zoomIn(_:)), "=", target: self),
            item("Zoom Out", #selector(zoomOut(_:)), "-", target: self),
            item("Zoom to Fit", #selector(zoomToFit(_:)), "0", target: self),
            item("Actual Size", #selector(zoomToActualSize(_:)), "1", target: self),
            .separator(),
            item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        NSApp.mainMenu = main
    }

    // MARK: Folder

    private func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        let target = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        folder = target
        photos = PhotoLibrary.photos(in: target)
        window.title = "PhotoCrop — \(target.path)"
        loader.keepOnly([])
        grid.thumbnails.removeAll()
        grid.photos = photos
        current = nil
        shownURL = nil
        photoView.setPhoto(nil)

        guard !photos.isEmpty else {
            photoView.status = "No JPEG photos in \(target.lastPathComponent). Press ⌘O to open another folder."
            setMode(.photo)
            return
        }
        let wanted = isDirectory.boolValue ? settings.lastPhoto(in: target) : url.lastPathComponent
        index = wanted.flatMap { name in photos.firstIndex { $0.lastPathComponent == name } } ?? 0
        setMode(isDirectory.boolValue ? settings.mode : .photo)
    }

    /// Re-reads the folder, so photos added or deleted on the card since opening are picked up.
    private func refreshPhotoList() {
        guard let folder else { return }
        let fresh = PhotoLibrary.photos(in: folder)
        guard fresh != photos else { return }
        let name = currentURL?.lastPathComponent
        photos = fresh
        index = name.flatMap { n in photos.firstIndex { $0.lastPathComponent == n } } ?? min(index, max(photos.count - 1, 0))
        grid.photos = photos
    }

    @objc private func volumesChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didUnmountNotification {
            guard let folder, !FileManager.default.fileExists(atPath: folder.path) else { return }
            self.folder = nil
            photos = []
            current = nil
            shownURL = nil
            loader.keepOnly([])
            grid.thumbnails.removeAll()
            grid.photos = []
            photoView.setPhoto(nil)
            photoView.status = "Card removed. Insert it again, or press ⌘O to open a folder."
            setMode(.photo)
        } else if photos.isEmpty, let card = PhotoLibrary.findCameraCard() {
            open(card)
        }
    }

    @objc func openFolder(_ sender: Any?) {
        guard window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of photos, or your camera card"
        panel.directoryURL = folder
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    @objc func chooseDestination(_ sender: Any?) {
        guard window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where saved photos go"
        panel.directoryURL = settings.destination
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            setDestination(url)
        }
    }

    private func setDestination(_ url: URL) {
        settings.destination = url
        refreshHUD()
        toast.show("Saving to \(displayName(url))")
    }

    @objc func selectWholePhoto(_ sender: Any?) { if mode == .photo { photoView.selectWholePhoto() } }
    @objc func toggleMode(_ sender: Any?) { setMode(mode == .grid ? .photo : .grid) }
    @objc func zoomIn(_ sender: Any?) { mode == .grid ? grid.resizeThumbnails(by: 1.25) : photoView.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { mode == .grid ? grid.resizeThumbnails(by: 0.8) : photoView.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { if mode == .photo { photoView.zoomToFit() } }
    @objc func zoomToActualSize(_ sender: Any?) { if mode == .photo { photoView.zoomToActualSize() } }

    // MARK: Trash

    @objc func moveToTrash(_ sender: Any?) {
        guard let url = currentURL else { return }
        do {
            let inTrash = try PhotoLibrary.moveToTrash(url)
            trashed.append((url, inTrash))
            removeFromList(url)
            toast.show("Moved \(url.lastPathComponent) to the Trash — ⌘Z to put it back", duration: 4)
        } catch {
            toast.show("Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)", isError: true, duration: 6)
        }
    }

    @objc func undoMoveToTrash(_ sender: Any?) {
        guard let last = trashed.popLast() else {
            toast.show("Nothing to put back")
            return
        }
        do {
            try PhotoLibrary.restore(last.inTrash, to: last.original)
        } catch {
            toast.show("Couldn't put back \(last.original.lastPathComponent) — it may have left the Trash", isError: true, duration: 6)
            return
        }
        refreshPhotoList()
        if let i = photos.firstIndex(of: last.original) { index = i }
        showCurrent()
        toast.show("Put back \(last.original.lastPathComponent)")
    }

    @objc func showPhotoInFinder(_ sender: Any?) {
        if let url = currentURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openFocused(_ sender: Any?) { setMode(.photo) }

    /// The next photo takes the removed one's place.
    private func removeFromList(_ url: URL) {
        guard let i = photos.firstIndex(of: url) else { return }
        photos.remove(at: i)
        grid.photos = photos
        index = min(i, max(photos.count - 1, 0))
        if photos.isEmpty {
            current = nil
            shownURL = nil
            photoView.setPhoto(nil)
            photoView.status = "No photos left in this folder."
            refreshHUD()
            return
        }
        showCurrent()
    }

    /// Brings the view up to date with `index`.
    private func showCurrent() {
        switch mode {
        case .photo:
            show(index)
        case .grid:
            grid.focusIndex = index
            grid.scrollToFocus()
            if let folder, let url = currentURL { settings.setLastPhoto(url.lastPathComponent, in: folder) }
            refreshHUD()
        }
    }

    func gridView(_ grid: GridView, menuFor index: Int) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(openFocused(_:))), ("Show in Finder", #selector(showPhotoInFinder(_:))),
                                ("Move to Trash", #selector(moveToTrash(_:)))] {
            if title == "Move to Trash" { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: title == "Move to Trash" ? "\u{8}" : "")
            entry.target = self
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: Grid and photo views

    private func setMode(_ newMode: ViewMode) {
        mode = newMode
        if folder != nil { settings.mode = newMode }
        photoView.isHidden = newMode != .photo
        gridScroll.isHidden = newMode != .grid
        switch newMode {
        case .grid:
            photoView.isPeeking = false
            refreshPhotoList()
            grid.focusIndex = index
            grid.relayout()
            grid.centerOnFocus()
            window.makeFirstResponder(grid)
        case .photo:
            // Coming back to the photo that's already loaded keeps its crop and zoom.
            if currentURL != shownURL { show(index) }
            window.makeFirstResponder(photoView)
        }
        refreshHUD()
    }

    func gridView(_ grid: GridView, open index: Int) {
        self.index = index
        setMode(.photo)
    }

    func gridView(_ grid: GridView, didFocus index: Int) {
        self.index = index
        if let folder, let url = currentURL { settings.setLastPhoto(url.lastPathComponent, in: folder) }
        refreshHUD()
    }

    private func show(_ newIndex: Int) {
        guard !photos.isEmpty else { return }
        index = min(max(newIndex, 0), photos.count - 1)
        let url = photos[index]
        current = nil
        shownURL = url
        placeholderFor = nil
        photoView.isPeeking = false
        photoView.setPhoto(nil)
        if let folder { settings.setLastPhoto(url.lastPathComponent, in: folder) }

        // Keep a window of decoded previews around the current photo, nearest-ahead first.
        let neighbours = [index + 1, index + 2, index - 1, index + 3, index - 2].filter(photos.indices.contains)
        loader.keepOnly(Set(([index] + neighbours).map { photos[$0] }))

        if let hit = loader.cached(url) {
            display(hit, for: url)
        } else {
            if let thumbnail = grid.thumbnails.thumbnail(for: url),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil), let info = PhotoInfo(source: source) {
                // Show the grid thumbnail at once; the sharp preview replaces it without resetting anything.
                display(LoadedPhoto(info: info, preview: thumbnail), for: url)
                placeholderFor = url
            } else {
                photoView.status = "Loading…"
            }
            loader.load(url, priority: .veryHigh) { [weak self] photo in self?.display(photo, for: url) }
        }
        for (n, i) in neighbours.enumerated() {
            loader.load(photos[i], priority: n == 0 ? .high : .normal)
        }
        refreshHUD()
    }

    private func display(_ photo: LoadedPhoto?, for url: URL) {
        guard url == currentURL, url == shownURL else { return }
        var turned = photo?.rotated(rotations[url] ?? 0)
        turned?.info.angle = angles[url] ?? 0
        if placeholderFor == url, let turned {
            placeholderFor = nil
            current = turned
            photoView.replacePreview(turned)
            return
        }
        current = turned
        photoView.status = photo == nil ? "Couldn't read \(url.lastPathComponent)." : nil
        photoView.setPhoto(current)
        refreshHUD()
    }

    private func step(_ delta: Int) {
        guard !photos.isEmpty else { return }
        guard photos.indices.contains(index + delta) else {
            toast.show(delta > 0 ? "That's the last photo" : "That's the first photo")
            return
        }
        show(index + delta)
    }

    func photoViewNeedsFullResolution(_ view: PhotoView) {
        guard let url = currentURL, current != nil, placeholderFor == nil, view.fullImage == nil else { return }
        let turns = rotations[url] ?? 0
        let request = "\(turns)|\(url.path)"
        guard fullResolutionRequest != request else { return }
        fullResolutionRequest = request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = PhotoDecoder.fullResolution(of: url).flatMap { PhotoDecoder.rotate($0, quarterTurns: turns) }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.fullResolutionRequest == request { self.fullResolutionRequest = nil }
                if self.shownURL == url, (self.rotations[url] ?? 0) == turns { self.photoView.fullImage = image }
            }
        }
    }

    // MARK: Rotation

    private func rotate(_ delta: Int) {
        guard let url = currentURL else { return }
        let turns = ((rotations[url] ?? 0) + delta + 4) % 4
        rotations[url] = turns == 0 ? nil : turns
        if mode == .photo, let photo = loader.cached(url) { display(photo, for: url) }
        grid.redraw(url)
        refreshHUD()
        toast.show("Rotated \(rotationLabel(for: url))")
    }

    private func straighten(to angle: Double) {
        guard let url = currentURL, current != nil else { return }
        let clamped = (min(max(angle, -45), 45) * 100).rounded() / 100
        angles[url] = clamped == 0 ? nil : clamped
        current?.info.angle = clamped
        photoView.setAngle(clamped)
        refreshHUD()
    }

    private func straighten(by delta: Double) {
        straighten(to: (current?.info.angle ?? 0) + delta)
    }

    private func resetRotation() {
        guard let url = currentURL else { return }
        rotations[url] = nil
        angles[url] = nil
        if let photo = loader.cached(url) { display(photo, for: url) }
        grid.redraw(url)
        refreshHUD()
        toast.show("Original orientation")
    }

    func photoView(_ view: PhotoView, straightenTo angle: Double) {
        straighten(to: angle)
    }

    /// Total rotation shown in the status bar, e.g. "90°" or "-1.5°".
    private func rotationLabel(for url: URL) -> String {
        var total = Double(rotations[url] ?? 0) * 90 + (angles[url] ?? 0)
        if total > 180 { total -= 360 }
        return total == 0 ? "0°" : String(format: "%g°", total)
    }

    // MARK: Keys

    func photoView(_ view: PhotoView, keyDown event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: step(-1)
        case 124: step(1)
        case 36, 76: saveCrop()
        case 53:
            // Esc steps back: clear the crop, then zoom out, then the grid.
            if view.selection != nil {
                view.selection = nil
            } else if view.isZoomedIn {
                view.zoomToFit()
            } else {
                setMode(.grid)
            }
        case 49: if !event.isARepeat { view.isPeeking = true }
        case 51, 117: return deleteKey(event)
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
            let shift = event.modifierFlags.contains(.shift)
            switch key {
            case "[": straighten(by: -0.5)
            case "]": straighten(by: 0.5)
            case "{": straighten(by: -0.1)
            case "}": straighten(by: 0.1)
            case "z": shift ? view.zoomStepOut(at: view.mouseLocation) : view.zoomStepIn(at: view.mouseLocation)
            case "a": cycleRatio(shift ? -1 : 1)
            case "x": flipRatio()
            default: return handleSharedKey(key, shift: shift)
            }
        }
        return true
    }

    func photoView(_ view: PhotoView, keyUp event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        view.isPeeking = false
        return true
    }

    func gridView(_ grid: GridView, keyDown event: NSEvent) -> Bool {
        if event.keyCode == 51 || event.keyCode == 117 { return deleteKey(event) }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return handleSharedKey(key, shift: event.modifierFlags.contains(.shift))
    }

    /// ⌘⌫ moves to the Trash (normally caught by the menu first); a bare ⌫ only explains, so a stray
    /// keypress can't trash anything.
    private func deleteKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            moveToTrash(nil)
        } else {
            toast.show("Press ⌘⌫ to move this photo to the Trash")
        }
        return true
    }

    /// Keys that work the same in the grid and the photo view.
    private func handleSharedKey(_ key: String, shift: Bool) -> Bool {
        switch key {
        case "1", "2", "3", "4", "5": rate(Int(key)!)
        case "0": rate(0)
        case "f": saveWholePhoto()
        case "r": rotate(shift ? -1 : 1)
        case "g": setMode(mode == .grid ? .photo : .grid)
        case "q": setQuality(settings.quality.toggled)
        case "d": chooseDestination(nil)
        default: return false
        }
        return true
    }

    /// Pressing a photo's current rating again clears it.
    private func rate(_ stars: Int) {
        guard let url = currentURL else { return }
        records.setRating(stars == records.rating(for: url) ? 0 : stars, for: url)
        grid.redraw(url)
        refreshHUD()
    }

    private func cycleRatio(_ delta: Int) {
        let count = AspectRatio.presets.count
        settings.ratioIndex = (settings.ratioIndex + delta + count) % count
        applyRatio()
        toast.show("Ratio \(ratio.label(flipped: settings.ratioFlipped))")
    }

    private func flipRatio() {
        guard !ratio.isFree else {
            toast.show("Free crop — press A to pick a ratio first")
            return
        }
        settings.ratioFlipped.toggle()
        applyRatio()
        toast.show("Ratio \(ratio.label(flipped: settings.ratioFlipped))")
    }

    private func applyRatio() {
        photoView.ratio = ratio.value(flipped: settings.ratioFlipped)
        photoView.conformSelectionToRatio()
        refreshHUD()
    }

    private func setQuality(_ quality: QualityMode) {
        settings.quality = quality
        refreshHUD()
        switch quality {
        case .high: toast.show("High quality — re-encoded JPEG 95%, exact crop edges")
        case .original: toast.show("Original quality — lossless; edges may grow a few px to the JPEG grid")
        }
    }

    // MARK: Status bar

    func statusBar(_ bar: StatusBarView, clicked item: HUDItem, in rect: CGRect) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ action: Selector? = nil, key: String = "", checked: Bool = false,
                 object: Any? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = []
            entry.target = self
            entry.state = checked ? .on : .off
            entry.representedObject = object
            entry.isEnabled = action != nil
            menu.addItem(entry)
            return entry
        }

        switch item {
        case .mode(let newMode):
            setMode(newMode)
            return
        case .star(let n):
            rate(n)
            return
        case .destination:
            for url in settings.recentDestinations where FileManager.default.fileExists(atPath: url.path) {
                let entry = add(displayName(url), #selector(pickDestination(_:)), checked: url.path == settings.destination.path,
                                object: url)
                entry.toolTip = url.path
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            menu.addItem(.separator())
            add("Choose Folder…", #selector(chooseDestination(_:)), key: "d")
            add("Show in Finder", #selector(showDestinationInFinder(_:)))
        case .ratio:
            for (i, preset) in AspectRatio.presets.enumerated() {
                add(preset.label(flipped: settings.ratioFlipped), #selector(pickRatio(_:)), checked: i == settings.ratioIndex, object: i)
            }
            menu.addItem(.separator())
            add("Swap Landscape / Portrait", #selector(swapRatio(_:)), key: "x")
        case .quality:
            add(QualityMode.original.label, #selector(pickQuality(_:)), checked: settings.quality == .original, object: "original")
            add(QualityMode.high.label, #selector(pickQuality(_:)), checked: settings.quality == .high, object: "high")
            menu.addItem(.separator())
            add("Original keeps the camera's exact pixels; edges may grow a few px.")
            add("High re-encodes, with exact crop edges.")
            add("Straightened photos are always re-encoded (Original → JPEG 100%).")
        case .rotation:
            add("Rotate 90° Clockwise", #selector(rotateClockwise(_:)), key: "r")
            add("Rotate 90° Counter-clockwise", #selector(rotateCounterClockwise(_:)), key: "R")
            menu.addItem(.separator())
            add("Straighten +0.5°", #selector(straightenClockwise(_:)), key: "]")
            add("Straighten −0.5°", #selector(straightenCounterClockwise(_:)), key: "[")
            add("Tip: ⌥-drag along the horizon to level it")
            add("Tip: twist two fingers on the trackpad")
            menu.addItem(.separator())
            let reset = add("Reset Rotation", #selector(resetRotation(_:)))
            reset.isEnabled = currentURL.map { rotationLabel(for: $0) != "0°" } ?? false
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY - menu.size.height - 4), in: bar)
    }

    @objc private func pickDestination(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { setDestination(url) }
    }

    @objc private func showDestinationInFinder(_ sender: Any?) { NSWorkspace.shared.open(settings.destination) }

    @objc private func pickRatio(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        settings.ratioIndex = i
        applyRatio()
    }

    @objc private func swapRatio(_ sender: Any?) { flipRatio() }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let quality = QualityMode(rawValue: raw) { setQuality(quality) }
    }

    @objc private func rotateClockwise(_ sender: Any?) { rotate(1) }
    @objc private func rotateCounterClockwise(_ sender: Any?) { rotate(-1) }
    @objc private func straightenClockwise(_ sender: Any?) { straighten(by: 0.5) }
    @objc private func straightenCounterClockwise(_ sender: Any?) { straighten(by: -0.5) }
    @objc private func resetRotation(_ sender: Any?) { resetRotation() }

    private func refreshHUD() {
        var hud = HUDInfo()
        hud.mode = mode
        if let url = currentURL {
            hud.name = url.lastPathComponent
            hud.position = "\(index + 1) / \(photos.count)"
            hud.rating = records.rating(for: url)
            hud.savedCount = records.savedCount(for: url)
            hud.rotation = rotationLabel(for: url)
        }
        hud.ratio = ratio.label(flipped: settings.ratioFlipped)
        hud.quality = settings.quality == .original ? "Original" : "High"
        hud.destination = displayName(settings.destination)
        statusBar.hud = hud
        photoView.rating = hud.rating
        photoView.savedCount = hud.savedCount
    }

    // MARK: Saving

    private func saveCrop() {
        guard let url = currentURL, let photo = current else { return }
        guard let rect = photoView.selection else {
            toast.show("Drag on the photo to choose a crop first — or press F to save the whole photo")
            return
        }
        guard let destination = destinationFolder() else { return }
        let note = straightenNote(photo.info)
        toast.show("Saving crop…", duration: 60)
        exporter.saveCrop(of: url, info: photo.info, rect: rect, quality: settings.quality, to: destination) { [weak self] result in
            self?.finishSave(result, source: url, note: note)
        }
    }

    /// Works from the grid too, where the photo hasn't been loaded: its header is enough.
    private func saveWholePhoto() {
        guard let url = currentURL, let destination = destinationFolder() else { return }
        var info: PhotoInfo
        if let current, url == shownURL {
            info = current.info
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let header = PhotoInfo(source: source) else {
                toast.show("Couldn't read \(url.lastPathComponent)", isError: true)
                return
            }
            info = header
            info.quarterTurns = rotations[url] ?? 0
            info.angle = angles[url] ?? 0
        }
        let note = straightenNote(info)
        toast.show("Saving photo…", duration: 60)
        exporter.saveFull(url, info: info, quality: settings.quality, to: destination) { [weak self] result in
            self?.finishSave(result, source: url, note: note)
        }
    }

    private func straightenNote(_ info: PhotoInfo) -> String {
        guard info.angle != 0 else { return "" }
        return settings.quality == .original ? " — straightened, so re-encoded at JPEG 100%" : ""
    }

    private func finishSave(_ result: Result<URL, Error>, source: URL, note: String) {
        switch result {
        case .success(let output):
            records.recordSave(source, output: output)
            toast.show("Saved \(output.lastPathComponent) to \(displayName(output.deletingLastPathComponent()))\(note)",
                       duration: note.isEmpty ? 2.5 : 4)
        case .failure(let error):
            toast.show("Couldn't save: \(error.localizedDescription)", isError: true, duration: 6)
        }
        grid.redraw(source)
        refreshHUD()
    }

    private func destinationFolder() -> URL? {
        let destination = settings.destination
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return destination
        }
        toast.show("Save folder \(destination.lastPathComponent) doesn't exist any more — choose another", isError: true)
        chooseDestination(nil)
        return nil
    }

    private func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }
}
