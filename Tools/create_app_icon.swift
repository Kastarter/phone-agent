import AppKit
import Foundation
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor.black.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor.white.setStroke()
let phone = NSBezierPath(roundedRect: NSRect(x: 294, y: 156, width: 436, height: 712), xRadius: 86, yRadius: 86)
phone.lineWidth = 38; phone.stroke()
let speaker = NSBezierPath(roundedRect: NSRect(x: 450, y: 793, width: 124, height: 20), xRadius: 10, yRadius: 10)
NSColor.white.setFill(); speaker.fill()
let home = NSBezierPath(roundedRect: NSRect(x: 438, y: 207, width: 148, height: 18), xRadius: 9, yRadius: 9); home.fill()
// A physical pointer inside the phone gives the accessory assistant its own mark.
let pointer = NSBezierPath()
pointer.move(to: NSPoint(x: 438, y: 657));pointer.line(to: NSPoint(x: 438, y: 377))
pointer.line(to: NSPoint(x: 504, y: 443));pointer.line(to: NSPoint(x: 568, y: 332))
pointer.line(to: NSPoint(x: 613, y: 357));pointer.line(to: NSPoint(x: 549, y: 468))
pointer.line(to: NSPoint(x: 648, y: 468));pointer.close();pointer.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 1024 * 3, bitsPerPixel: 24)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
