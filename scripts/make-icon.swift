import AppKit

// Reuse the native symbol from the picker and menu bar, at every macOS icon size.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let cyan = NSColor(calibratedRed: 0.20, green: 0.76, blue: 0.87, alpha: 1)
let symbol = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 540, weight: .regular))!
    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [cyan]))!

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedWhite: 0.085, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
            xRadius: 200, yRadius: 200).fill()
        let width: CGFloat = 600
        let height = width * symbol.size.height / symbol.size.width
        symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2,
                              width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
