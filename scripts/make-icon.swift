#!/usr/bin/swift
// Draws the app icon (a lit house on a night-sky tile) and writes macos/AppIcon.icns,
// docs/icon.png and the iPhone app's icon. Usage: ./scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// `fullBleed` is the iOS form: the artwork fills the square and the system rounds the corners.
func render(_ pixels: Int, fullBleed: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: fullBleed ? 3 : 4, hasAlpha: !fullBleed, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: fullBleed ? 32 : 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    if fullBleed {
        // The tile is drawn for the macOS grid; scale it up until it covers the canvas.
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
        ctx.translateBy(x: -512, y: -512)
    }
    // macOS icon grid: an 824 pt tile centred on a 1024 pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = fullBleed ? CGPath(rect: tile, transform: nil)
        : CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    if !fullBleed {
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    }
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let sky = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.05, green: 0.07, blue: 0.16, alpha: 1).cgColor,
        NSColor(srgbRed: 0.13, green: 0.16, blue: 0.36, alpha: 1).cgColor,
        NSColor(srgbRed: 0.36, green: 0.24, blue: 0.52, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Warm light spilling out of the house.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 1, green: 0.72, blue: 0.36, alpha: 0.75).cgColor,
        NSColor(srgbRed: 1, green: 0.62, blue: 0.3, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 430), endRadius: 430, options: [])
    ctx.restoreGState()

    // The house: SF Symbol, tinted warm white.
    let config = NSImage.SymbolConfiguration(pointSize: fullBleed ? 380 : 430, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let box = CGRect(x: 512 - size.width / 2, y: 512 - size.height / 2 - 6, width: size.width, height: size.height)
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(srgbRed: 1, green: 0.95, blue: 0.86, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 40, color: NSColor(srgbRed: 1, green: 0.7, blue: 0.3, alpha: 0.7).cgColor)
        tinted.draw(in: box)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("HouseControl.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("macos/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try render(256).write(to: root.appendingPathComponent("docs/icon.png"))
try render(1024, fullBleed: true)
    .write(to: root.appendingPathComponent("ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
print(iconutil.terminationStatus == 0 ? "✓ macos/AppIcon.icns, docs/icon.png, iOS AppIcon" : "✗ iconutil failed")
