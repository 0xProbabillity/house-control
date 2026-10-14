#!/usr/bin/swift
// Draws the background of the disk image window (the app on the left, Applications on the
// right, an arrow between them) and writes macos/dmg-background.tiff with 1x and 2x images.
// Usage: ./scripts/make-dmg-background.swift   (scripts/release-mac.sh uses the result)
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
// Must match the window and icon positions in scripts/dmg-settings.py.
let size = CGSize(width: 640, height: 400)
let appCenter = CGPoint(x: 170, y: 200)
let applicationsCenter = CGPoint(x: 470, y: 200)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The context is already scaled from points to the rep's pixels (rep.size is in points).
    let ctx = NSGraphicsContext.current!.cgContext
    // AppKit's origin is bottom-left; the layout above is written top-down.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // A light dawn sky: Finder draws the icon labels in black on a background picture,
    // even in dark mode, so the window has to stay light.
    let space = CGColorSpaceCreateDeviceRGB()
    let sky = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.93, green: 0.94, blue: 0.98, alpha: 1).cgColor,
        NSColor(red: 0.98, green: 0.95, blue: 0.91, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // A warm glow under the app, as if its windows were lit.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 1.0, green: 0.66, blue: 0.30, alpha: 0.28).cgColor,
        NSColor(red: 1.0, green: 0.72, blue: 0.36, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: appCenter, startRadius: 0, endCenter: appCenter, endRadius: 150, options: [])

    // The arrow from the app to Applications.
    let from = CGPoint(x: appCenter.x + 78, y: appCenter.y)
    let to = CGPoint(x: applicationsCenter.x - 78, y: appCenter.y)
    ctx.setStrokeColor(NSColor(red: 0.16, green: 0.18, blue: 0.26, alpha: 0.45).cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 9])
    ctx.move(to: from)
    ctx.addLine(to: CGPoint(x: to.x - 6, y: to.y))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: to.x - 12, y: to.y - 10))
    ctx.addLine(to: to)
    ctx.addLine(to: CGPoint(x: to.x - 12, y: to.y + 10))
    ctx.strokePath()

    // The caption, drawn the right way up.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let caption = NSAttributedString(string: "Drag House Control into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 0.9),
        .paragraphStyle: style,
    ])
    caption.draw(in: CGRect(x: 0, y: 72, width: size.width, height: 22))
    let hint = NSAttributedString(string: "Then open it from Applications and look for the house in the menu bar.", attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 0.5),
        .paragraphStyle: style,
    ])
    hint.draw(in: CGRect(x: 0, y: 50, width: size.width, height: 18))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let out = root.appendingPathComponent("macos/dmg-background.tiff")
try! image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: out)
print("✓ \(out.path)")
