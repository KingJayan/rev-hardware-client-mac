// renders logo.png onto a 1024 macos icon tile
import AppKit
let a = CommandLine.arguments
guard let logo = NSImage(contentsOfFile: a[1]) else { exit(1) }
let s: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.4); sh.shadowBlurRadius = 20; sh.shadowOffset = NSSize(width: 0, height: -10)
sh.set()
NSColor.black.setFill(); path.fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 1, alpha: 0.08).setStroke(); path.lineWidth = 3; path.stroke()
let w: CGFloat = 600, h = w * logo.size.height / logo.size.width
logo.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
