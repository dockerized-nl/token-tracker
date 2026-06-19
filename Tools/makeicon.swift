import AppKit

// Renders a 1024x1024 white/blue chart icon to the path given as argv[1].
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let s = CGFloat(size)
// Rounded background with blue gradient.
let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
let path = CGPath(roundedRect: bgRect.insetBy(dx: 40, dy: 40), cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(path); ctx.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1),
    CGColor(red: 0.07, green: 0.32, blue: 0.78, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// White bars (a little bar chart).
let barColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
ctx.setFillColor(barColor)
let heights: [CGFloat] = [0.30, 0.50, 0.42, 0.66, 0.82]
let barW = s * 0.085
let gap = s * 0.045
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (s - totalW) / 2
let baseY = s * 0.30
for h in heights {
    let barH = s * 0.42 * h + s * 0.06
    let r = CGRect(x: x, y: baseY, width: barW, height: barH)
    let bp = CGPath(roundedRect: r, cornerWidth: barW * 0.32, cornerHeight: barW * 0.32, transform: nil)
    ctx.addPath(bp); ctx.fillPath()
    x += barW + gap
}
// Trend line dot accent
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.setLineWidth(s * 0.018)
ctx.setLineCap(.round)
var first = true
x = (s - totalW) / 2 + barW / 2
for h in heights {
    let py = baseY + s * 0.42 * h + s * 0.06 + s * 0.05
    if first { ctx.move(to: CGPoint(x: x, y: py)); first = false }
    else { ctx.addLine(to: CGPoint(x: x, y: py)) }
    x += barW + gap
}
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
