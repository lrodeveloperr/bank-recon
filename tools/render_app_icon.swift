import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift tools/render_app_icon.swift OUTPUT.png\n", stderr)
    exit(64)
}

let size = NSSize(width: 1_024, height: 1_024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1_024,
    pixelsHigh: 1_024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: false,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("unable to create icon bitmap") }

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("unable to create graphics context") }
NSGraphicsContext.current = context
context.imageInterpolation = .high

let canvas = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 226, yRadius: 226)
let background = NSGradient(colors: [
    NSColor(red: 0.035, green: 0.082, blue: 0.160, alpha: 1),
    NSColor(red: 0.055, green: 0.180, blue: 0.290, alpha: 1)
])!
background.draw(in: canvas, angle: -48)

let leftCard = NSBezierPath(roundedRect: NSRect(x: 150, y: 215, width: 320, height: 590), xRadius: 54, yRadius: 54)
NSColor(red: 0.11, green: 0.49, blue: 0.96, alpha: 1).setFill()
leftCard.fill()

let rightCard = NSBezierPath(roundedRect: NSRect(x: 554, y: 215, width: 320, height: 590), xRadius: 54, yRadius: 54)
NSColor(red: 0.13, green: 0.75, blue: 0.61, alpha: 1).setFill()
rightCard.fill()

NSColor.white.withAlphaComponent(0.92).setStroke()
for y in [650.0, 545.0, 440.0] {
    let leftLine = NSBezierPath()
    leftLine.lineWidth = 34
    leftLine.lineCapStyle = .round
    leftLine.move(to: NSPoint(x: 225, y: y))
    leftLine.line(to: NSPoint(x: 395, y: y))
    leftLine.stroke()

    let rightLine = NSBezierPath()
    rightLine.lineWidth = 34
    rightLine.lineCapStyle = .round
    rightLine.move(to: NSPoint(x: 629, y: y))
    rightLine.line(to: NSPoint(x: 799, y: y))
    rightLine.stroke()
}

let connector = NSBezierPath()
connector.lineWidth = 44
connector.lineCapStyle = .round
connector.move(to: NSPoint(x: 455, y: 512))
connector.line(to: NSPoint(x: 569, y: 512))
NSColor.white.withAlphaComponent(0.72).setStroke()
connector.stroke()

let checkCircle = NSBezierPath(ovalIn: NSRect(x: 337, y: 92, width: 350, height: 350))
NSColor(red: 0.025, green: 0.115, blue: 0.205, alpha: 1).setFill()
checkCircle.fill()
NSColor.white.withAlphaComponent(0.22).setStroke()
checkCircle.lineWidth = 12
checkCircle.stroke()

let check = NSBezierPath()
check.lineWidth = 62
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: 423, y: 261))
check.line(to: NSPoint(x: 488, y: 196))
check.line(to: NSPoint(x: 614, y: 332))
NSColor.white.setStroke()
check.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("unable to encode icon")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)

