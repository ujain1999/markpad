import AppKit
import Foundation

// Turns supplied icon artwork into a macOS master icon: trims the flat
// background, drops it out for transparency, and seats the shape on a
// 1024×1024 canvas at the proportions macOS expects.
//
//   swift tools/PrepareIcon.swift <source.png> <out.png>

let args = CommandLine.arguments
guard args.count > 2,
      let source = NSImage(contentsOfFile: args[1]),
      let src = NSBitmapImageRep(data: source.tiffRepresentation!) else {
    FileHandle.standardError.write("cannot read source\n".data(using: .utf8)!)
    exit(1)
}

let width = src.pixelsWide, height = src.pixelsHigh

/// True when a pixel belongs to the flat backdrop rather than the artwork.
func isBackdrop(_ x: Int, _ y: Int) -> Bool {
    guard let c = src.colorAt(x: x, y: y) else { return true }
    return c.redComponent > 0.93 && c.greenComponent > 0.93 && c.blueComponent > 0.93
}

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where !isBackdrop(x, y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write("no artwork found\n".data(using: .utf8)!)
    exit(1)
}

// Keep the shape square: the artwork is a rounded square, so use the larger side.
let artWidth = maxX - minX + 1, artHeight = maxY - minY + 1
let side = max(artWidth, artHeight)
let cropX = minX - (side - artWidth) / 2
let cropY = minY - (side - artHeight) / 2
print("artwork \(artWidth)×\(artHeight) at (\(minX),\(minY)) in \(width)×\(height)")

// macOS seats the rounded body in 824 of a 1024 canvas, leaving clear margins.
let canvas: CGFloat = 1024
let body: CGFloat = 824
let inset = (canvas - body) / 2
let radius = body * 0.2237

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
out.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high

// Clipping to the rounded shape drops the backdrop, including the pale fringe
// the artwork's own anti-aliasing leaves just outside its edge.
let frame = NSRect(x: inset, y: inset, width: body, height: body)
NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75),
             xRadius: radius, yRadius: radius).setClip()

let cropped = NSImage(size: NSSize(width: side, height: side))
cropped.lockFocus()
source.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
            from: NSRect(x: cropX, y: height - cropY - side, width: side, height: side),
            operation: .copy, fraction: 1)
cropped.unlockFocus()
cropped.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
