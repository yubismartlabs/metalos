import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 0.065, green: 0.085, blue: 0.10, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 54, y: 54, width: 916, height: 916), cornerWidth: 205, cornerHeight: 205, transform: nil))
        context.fillPath()
        context.setStrokeColor(CGColor(red: 0.72, green: 0.94, blue: 0.38, alpha: 1))
        context.setLineWidth(58)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // MetalOS monogram: an M, drawn in the app's original accent color.
        context.move(to: CGPoint(x: 280, y: 335))
        context.addLine(to: CGPoint(x: 280, y: 690))
        context.addLine(to: CGPoint(x: 512, y: 460))
        context.addLine(to: CGPoint(x: 744, y: 690))
        context.addLine(to: CGPoint(x: 744, y: 335))
        context.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}

// ICNS stores these PNG representations directly; no image conversion is needed.
func lengthBytes(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (type, name) in [("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: destination.appendingPathComponent(name))
    chunks.append(Data(type.utf8)); chunks.append(lengthBytes(png.count + 8)); chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(lengthBytes(chunks.count + 8)); icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
