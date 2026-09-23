import AppKit
import Foundation

// Renders Markpad's app icon: an ink-dark squircle, a light "M", and an accent
// rule beneath it. Run: swift tools/MakeIcon.swift <output.iconset>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func render(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let margin = size * 0.085
    let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = rect.width * 0.2237
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.26, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
    ])
    gradient?.draw(in: body, angle: -90)

    // A hairline keeps the shape crisp on dark desktops.
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    body.lineWidth = max(1, size * 0.004)
    body.stroke()

    let letterSize = rect.height * 0.50
    let font = NSFont.systemFont(ofSize: letterSize, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1),
        .kern: -letterSize * 0.03,
    ]
    let letter = NSAttributedString(string: "M", attributes: attributes)
    let letterBounds = letter.size()
    let letterOrigin = NSPoint(
        x: rect.midX - letterBounds.width / 2,
        y: rect.midY - letterBounds.height / 2 + rect.height * 0.055)
    letter.draw(at: letterOrigin)

    let ruleWidth = rect.width * 0.30
    let ruleHeight = max(1, rect.height * 0.045)
    let rule = NSRect(x: rect.midX - ruleWidth / 2,
                      y: rect.minY + rect.height * 0.195,
                      width: ruleWidth, height: ruleHeight)
    NSColor(calibratedRed: 0.42, green: 0.60, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: rule, xRadius: ruleHeight / 2, yRadius: ruleHeight / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    guard let data = render(size: size) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent(name))
}
