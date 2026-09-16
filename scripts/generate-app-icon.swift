import AppKit

// Deterministic vector drawing; regenerate with:
// swift scripts/generate-app-icon.swift
// iconutil -c icns assets/AppIcon/Printroom.iconset -o assets/AppIcon/Printroom.icns
let destination = URL(fileURLWithPath: "assets/AppIcon", isDirectory: true)
let iconset = destination.appendingPathComponent("Printroom.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
  NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

func render(size: Int) throws -> Data {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  defer { NSGraphicsContext.restoreGraphicsState() }
  let context = NSGraphicsContext.current!.cgContext
  context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
    xRadius: 198, yRadius: 198)
  NSGradient(starting: color(53, 55, 55), ending: color(24, 26, 27))!.draw(in: tile, angle: -90)
  color(77, 77, 73).setStroke()
  tile.lineWidth = 3
  tile.stroke()

  // Three offset sheets, with a warm print emerging from a dark negative.
  func sheet(x: CGFloat, y: CGFloat, fill: NSColor, stroke: NSColor) {
    let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 412, height: 476),
      xRadius: 30, yRadius: 30)
    fill.setFill(); path.fill()
    stroke.setStroke(); path.lineWidth = 16; path.stroke()
  }
  sheet(x: 230, y: 338, fill: color(30, 32, 32), stroke: color(131, 112, 75))
  sheet(x: 302, y: 274, fill: color(35, 36, 35), stroke: color(187, 157, 99))
  let printRect = NSBezierPath(roundedRect: NSRect(x: 374, y: 210, width: 412, height: 476),
    xRadius: 30, yRadius: 30)
  NSGradient(starting: color(239, 214, 160), ending: color(194, 157, 86))!
    .draw(in: printRect, angle: -90)
  let aperture = NSBezierPath(roundedRect: NSRect(x: 409, y: 294, width: 342, height: 357),
    xRadius: 9, yRadius: 9)
  NSGradient(starting: color(65, 66, 59), ending: color(29, 33, 33))!
    .draw(in: aperture, angle: -90)
  // A simple exposure disc and horizon remain legible at Dock sizes.
  color(223, 193, 133).setFill()
  NSBezierPath(ovalIn: NSRect(x: 619, y: 521, width: 69, height: 69)).fill()
  let horizon = NSBezierPath()
  horizon.move(to: NSPoint(x: 430, y: 333))
  horizon.line(to: NSPoint(x: 521, y: 446))
  horizon.line(to: NSPoint(x: 596, y: 367))
  horizon.line(to: NSPoint(x: 655, y: 426))
  horizon.line(to: NSPoint(x: 730, y: 333))
  color(187, 157, 99).setStroke()
  horizon.lineWidth = 15; horizon.lineJoinStyle = .round; horizon.lineCapStyle = .round
  horizon.stroke()
  return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let suffix = scale == 2 ? "@2x" : ""
    try render(size: points * scale).write(to:
      iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
  }
}
try render(size: 1024).write(to: destination.appendingPathComponent("Printroom.png"))
print("Generated Printroom icon representations (16–1024 px)")
