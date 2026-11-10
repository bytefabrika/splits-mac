import AppKit
import CoreGraphics

// Splits app icon (run: swiftc -O tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <folder>; writes icon-1024.png, icon-dark-1024.png, preview.png):
// Splits app icon: a winding route in the shape of an S, with split markers along it, on the app's running colour.
// Full-bleed square, no shadows or glows: macOS masks the corners and adds its own lighting.
let size = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

func render(dark: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    // Background: warm orange at the top to a deeper pink-red at the bottom (CoreGraphics y goes up).
    let top = dark ? p3(0.32, 0.12, 0.10) : p3(1.00, 0.50, 0.27)
    let bottom = dark ? p3(0.20, 0.05, 0.12) : p3(0.93, 0.20, 0.35)
    let bg = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: s * 0.3, y: 0), end: CGPoint(x: s * 0.7, y: s), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The route: an S of two arcs, like the bends of a running track, run from the bottom-left end (start)
    // to the top-right end (finish). y goes up in CoreGraphics.
    let r = s * 0.158
    let topC = CGPoint(x: s * 0.5, y: s * 0.5 + r), bottomC = CGPoint(x: s * 0.5, y: s * 0.5 - r)
    func on(_ c: CGPoint, _ degrees: CGFloat) -> CGPoint {
        CGPoint(x: c.x + r * cos(degrees * .pi / 180), y: c.y + r * sin(degrees * .pi / 180))
    }
    let startAngle: CGFloat = 205, finishAngle: CGFloat = 25
    let route = CGMutablePath()
    route.move(to: on(bottomC, startAngle))
    // Bottom bend: from the left, under and round to the middle (counter-clockwise in y-up terms).
    route.addArc(center: bottomC, radius: r, startAngle: startAngle * .pi / 180, endAngle: (90 + 360) * .pi / 180, clockwise: false)
    // Top bend: from the middle, round the left and over to the right end.
    route.addArc(center: topC, radius: r, startAngle: 270 * .pi / 180, endAngle: finishAngle * .pi / 180, clockwise: true)

    let line = dark ? p3(1.0, 0.66, 0.50) : p3(1, 1, 1)
    let marker = dark ? p3(0.26, 0.08, 0.11) : p3(0.94, 0.30, 0.34)
    let width = s * 0.088
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(route); ctx.setStrokeColor(line); ctx.setLineWidth(width); ctx.strokePath()

    // Split markers on the line: one on each bend and one where they meet.
    for p in [on(bottomC, 300), CGPoint(x: s * 0.5, y: s * 0.5), on(topC, 150)] {
        ctx.setFillColor(marker)
        let d = width * 0.42
        ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
    }
    // Finish: a larger disc with a dark centre at the top end, so the run has a direction; the start is just the line's end.
    let start = on(bottomC, startAngle), finish = on(topC, finishAngle)
    ctx.setFillColor(line)
    ctx.fillEllipse(in: CGRect(x: finish.x - width * 0.95, y: finish.y - width * 0.95, width: width * 1.9, height: width * 1.9))
    ctx.setFillColor(marker)
    ctx.fillEllipse(in: CGRect(x: finish.x - width * 0.42, y: finish.y - width * 0.42, width: width * 0.84, height: width * 0.84))
    _ = start
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ path: String, px: Int) {
    let rep = NSBitmapImageRep(cgImage: image)
    let scaled = NSImage(size: NSSize(width: px, height: px))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: size, height: size)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    scaled.unlockFocus()
    let data = px == size ? rep.representation(using: .png, properties: [:])!
        : NSBitmapImageRep(data: scaled.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
save(render(dark: false), out + "/icon-1024.png", px: 1024)
save(render(dark: true), out + "/icon-dark-1024.png", px: 1024)
// A preview with the macOS corner mask and small sizes, to judge it the way people will see it.
let preview = NSImage(size: NSSize(width: 760, height: 300))
preview.lockFocus()
NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 760, height: 300).fill()
var x: CGFloat = 20
for (img, px) in [(render(dark: false), 256.0), (render(dark: true), 256.0), (render(dark: false), 64.0), (render(dark: false), 32.0), (render(dark: false), 16.0)] {
    let r = NSRect(x: x, y: (300 - px) / 2, width: px, height: px)
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: px * 0.225, yRadius: px * 0.225).addClip()
    NSImage(cgImage: img, size: NSSize(width: 1024, height: 1024)).draw(in: r)
    NSGraphicsContext.current?.restoreGraphicsState()
    x += px + 24
}
preview.unlockFocus()
try! NSBitmapImageRep(data: preview.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/preview.png"))
