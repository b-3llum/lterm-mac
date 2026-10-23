// Builds the app icon from assets/logo.svg and assets/logo-small.svg.
// Run from the repo root: swift scripts/make-icon.swift
// Like lterm's src/logo.rs, sizes under 40 px use the simpler small logo.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Sources/LtermMac/Resources/Assets.xcassets/AppIcon.appiconset")

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: root.appendingPathComponent("assets/\(name)")) else {
        fatalError("could not read assets/\(name) (NSImage reads SVG on macOS 14 and newer)")
    }
    return image
}

/// Renders `image` into a square PNG. `inset` is the empty margin on each side, as a fraction of the size.
func png(_ image: NSImage, pixels: Int, inset: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(pixels)
    image.draw(in: NSRect(x: side * inset, y: side * inset, width: side * (1 - 2 * inset), height: side * (1 - 2 * inset)))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let detailed = load("logo.svg")
let small = load("logo-small.svg")
// The logo's tile covers 94% of its square. Apple's icon grid puts the tile at 824 of 1024 px,
// so shrink the art until the tile matches that, and it sits right next to other Dock icons.
let inset = (1 - (824.0 / 1024.0) / 0.94) / 2

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels < 40 ? small : detailed, pixels: pixels, inset: inset).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: iconset.deletingLastPathComponent().appendingPathComponent("Contents.json"),
                                                       atomically: true, encoding: .utf8)
// A full-size PNG of the logo for the README, like lterm's assets/logo.png.
try png(detailed, pixels: 256, inset: 0).write(to: root.appendingPathComponent("assets/logo.png"))
print("wrote \(images.count) icon images to \(iconset.path)")
