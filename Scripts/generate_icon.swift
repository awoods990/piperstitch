import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Generates Resources/StitchPilot.icns from scratch: a simple, original
// mark (a rounded-square gradient background with a white running-stitch
// zigzag and a needle dot), drawn programmatically with CoreGraphics since
// no external design tools/assets are used in this project. Rerun after
// changing this file with:
//
//   swift Scripts/generate_icon.swift /tmp/stitchpilot-icon.iconset
//   iconutil -c icns /tmp/stitchpilot-icon.iconset -o Resources/StitchPilot.icns
func makeIcon(size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                         space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)

    // Background: rounded square with a vertical gradient (deep blue -> violet).
    let inset = s * 0.04
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colors = [CGColor(red: 0.09, green: 0.16, blue: 0.42, alpha: 1),
                  CGColor(red: 0.29, green: 0.19, blue: 0.55, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.resetClip()

    // A running-stitch zigzag across the middle: alternating short dashes,
    // suggesting embroidery stitches, in white.
    ctx.setLineWidth(s * 0.045)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    let midY = s * 0.52
    let amplitude = s * 0.09
    let startX = s * 0.20
    let endX = s * 0.80
    let segments = 7
    var points: [CGPoint] = []
    for i in 0...segments {
        let t = CGFloat(i) / CGFloat(segments)
        let x = startX + (endX - startX) * t
        let y = midY + (i % 2 == 0 ? -amplitude : amplitude)
        points.append(CGPoint(x: x, y: y))
    }
    ctx.setLineDash(phase: 0, lengths: [s * 0.05, s * 0.035])
    ctx.beginPath()
    ctx.move(to: points[0])
    for p in points.dropFirst() { ctx.addLine(to: p) }
    ctx.strokePath()

    // A small circle "needle point" at the trailing end.
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let dotR = s * 0.035
    ctx.fillEllipse(in: CGRect(x: endX - dotR, y: points.last!.y - dotR, width: dotR * 2, height: dotR * 2))

    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

guard CommandLine.arguments.count > 1 else {
    print("usage: swift generate_icon.swift <output .iconset directory>")
    exit(1)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (size, name) in sizes {
    let img = makeIcon(size: size)
    savePNG(img, to: outDir + "/" + name)
}
print("Wrote \(sizes.count) icon images to \(outDir)")
print("Next: iconutil -c icns \(outDir) -o Resources/StitchPilot.icns")
