import AppKit

@main
struct GenerateIcons {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "AskmeIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: generate-icons <iconset-directory>"])
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                    throw NSError(domain: "AskmeIcon", code: 2)
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                BrandIcon.drawAppIcon(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "AskmeIcon", code: 3)
                }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
