// Draws the PhotoCrop app icon and writes Resources/AppIcon.icns (plus a 1024 px preview PNG).
// Run from the project folder:  swift Tools/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.0) } as CFArray,
               locations: stops.map(\.1))!
}

/// The design lives on Apple's 1024-unit icon grid, drawn y-down; `size` is the output in pixels.
func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let unit = size / 1024
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: unit, y: -unit)

    // Tile: the standard 824-unit rounded square, with a soft shadow below.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1B1E4A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x4650C8, 0), (0x2A2D7A, 0.55), (0x15173D, 1)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Soft light from the top.
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 60), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 60), endRadius: 560, options: [])
    ctx.restoreGState()

    // The photo: a small sunset scene on a 4:3 card.
    let card = CGRect(x: 207, y: 292, width: 610, height: 458)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 34 * unit, color: color(0x000000, 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(color(0x2A1E57))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFC46B, 0), (0xFF7A6E, 0.45), (0xC4508F, 0.75), (0x6B3C9E, 1)]),
                           start: CGPoint(x: 0, y: card.minY), end: CGPoint(x: 0, y: card.maxY), options: [])
    // Sun with a glow.
    let sun = CGPoint(x: 598, y: 468)
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [color(0xFFF1C4, 0.9), color(0xFFD27A, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: sun, startRadius: 40, endCenter: sun, endRadius: 170, options: [])
    ctx.setFillColor(color(0xFFF3D2))
    ctx.fillEllipse(in: CGRect(x: sun.x - 58, y: sun.y - 58, width: 116, height: 116))
    // Two mountain ranges.
    func range(_ points: [CGPoint], _ fill: CGColor) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: card.minX - 10, y: card.maxY + 10))
        points.forEach { ctx.addLine(to: $0) }
        ctx.addLine(to: CGPoint(x: card.maxX + 10, y: card.maxY + 10))
        ctx.closePath()
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    range([CGPoint(x: 200, y: 600), CGPoint(x: 330, y: 500), CGPoint(x: 420, y: 560), CGPoint(x: 540, y: 470),
           CGPoint(x: 690, y: 585), CGPoint(x: 770, y: 540), CGPoint(x: 830, y: 575)], color(0x7A3F8F))
    range([CGPoint(x: 200, y: 660), CGPoint(x: 300, y: 610), CGPoint(x: 400, y: 648), CGPoint(x: 520, y: 575),
           CGPoint(x: 640, y: 660), CGPoint(x: 740, y: 620), CGPoint(x: 830, y: 655)], color(0x3A2468))

    // The crop: everything outside it dimmed, a thirds grid inside.
    let crop = CGRect(x: 330, y: 360, width: 420, height: 315)
    ctx.addRect(card.insetBy(dx: -2, dy: -2))
    ctx.addRect(crop)
    ctx.setFillColor(color(0x0B0A24, 0.55))
    ctx.fillPath(using: .evenOdd)
    ctx.setStrokeColor(color(0xFFFFFF, 0.4))
    ctx.setLineWidth(4)
    for k in 1...2 {
        let x = crop.minX + crop.width * CGFloat(k) / 3, y = crop.minY + crop.height * CGFloat(k) / 3
        ctx.move(to: CGPoint(x: x, y: crop.minY)); ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
        ctx.move(to: CGPoint(x: crop.minX, y: y)); ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Crop frame and its bold corner handles, which may overhang the photo.
    ctx.setStrokeColor(color(0xFFFFFF, 0.95))
    ctx.setLineWidth(6)
    ctx.stroke(crop)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3 * unit), blur: 8 * unit, color: color(0x000000, 0.35))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(24)
    ctx.setLineCap(.square)
    ctx.setLineJoin(.miter)
    let arm: CGFloat = 78, out: CGFloat = 9  // handles sit just outside the frame line
    for (cx, dx) in [(crop.minX - out, 1.0), (crop.maxX + out, -1.0)] {
        for (cy, dy) in [(crop.minY - out, 1.0), (crop.maxY + out, -1.0)] {
            ctx.move(to: CGPoint(x: cx + arm * dx, y: cy))
            ctx.addLine(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx, y: cy + arm * dy))
        }
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(ctx, size: CGFloat(size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let resources = root.appendingPathComponent("Resources")
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try! png(size: 1024).write(to: resources.appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
