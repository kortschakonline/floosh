import AppKit
import SwiftUI

/// Generiert das App-Icon aus den Marken-Pfaden in `BrandLogos.swift`:
/// dunkle Navy-Kachel (wie im Varianten-SVG) mit dem Doppel-Blitz.
///
/// Aufruf über `Tools/make-icon.sh` — kompiliert dieses File zusammen mit
/// `Sources/Floosh/BrandLogos.swift`, rendert das Iconset in allen Größen
/// und baut daraus `AppIcon.icns`.
@main
struct MakeIcon {
    static func main() throws {
        let outPath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "build/AppIcon.iconset"
        let out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let entries: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in entries {
            let data = render(pixels: px)
            try data.write(to: out.appendingPathComponent("\(name).png"))
        }
        print("✓ Iconset gerendert: \(out.path)")
    }

    static func render(pixels: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: pixels, height: pixels,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Auf y-nach-unten drehen, damit die SVG-Design-Koordinaten passen.
        let s = CGFloat(pixels) / 1024
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: s, y: -s)

        // Kachel im macOS-Icon-Raster: 824 pt zentriert, Radius 185,4 pt.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let rounded = CGPath(roundedRect: tile, cornerWidth: 185.4, cornerHeight: 185.4,
                             transform: nil)
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()

        // Navy-Verlauf um das Marken-Dunkelblau #0C0F27.
        let top = CGColor(srgbRed: 0x1A / 255, green: 0x20 / 255, blue: 0x45 / 255, alpha: 1)
        let bottom = CGColor(srgbRed: 0x08 / 255, green: 0x0A / 255, blue: 0x1C / 255, alpha: 1)
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [top, bottom] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 512, y: 100),
                               end: CGPoint(x: 512, y: 924), options: [])

        // Sanfter oranger Schein hinter dem Blitz.
        let glow = CGGradient(colorsSpace: space,
                              colors: [CGColor(srgbRed: 1, green: 0xAB / 255, blue: 0x11 / 255, alpha: 0.16),
                                       CGColor(srgbRed: 1, green: 0xAB / 255, blue: 0x11 / 255, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 540), endRadius: 430,
                               options: [])

        // Doppel-Blitz zentriert, 520 pt hoch.
        let design = LogoPaths.boltDesign
        let scale = 520 / design.height
        let dx = 512 - design.midX * scale
        let dy = 512 - design.midY * scale
        let t: (CGPoint) -> CGPoint = {
            CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy)
        }
        ctx.addPath(LogoPaths.boltFrame(t: t).cgPath)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.addPath(LogoPaths.boltAccent(t: t).cgPath)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0xAB / 255, blue: 0x11 / 255, alpha: 1))
        ctx.fillPath()

        ctx.restoreGState()

        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }
}
