// Cuts the menu-bar icon choices out of the brand exploration sheets into native/Resources/MenuBarIcons/.
// Build once:  swiftc -O scripts/cut-menu-bar-icons.swift -o /tmp/cut
// Usage:       cut <flood|lift|lum> <sheet.png> <x> <y> <w> <h> <out.png> [template-out.png]
//   flood  flat art on a plain card: flood-fills the card colour from the crop's edge (eyes survive)
//   lift   3D renders: Vision's foreground mask, with enclosed holes put back
// Output is trimmed and scaled to 192 px on the long side. The crops that produced the bundled set
// (sheets in brand/exploration/, flat Arranger from brand/variants/menusprite-logo-flat.png):
//   sprite-library-concepts.png, flood, with template:
//     row 1 y 165 h 275, row 2 y 565 h 290; x 32 / 328 / 634 / 936 / 1240, w 262
//     Peek Bitwing Droplet Mochi Comet / Bud Batlet Tilekin Orbit Fold
//   slim-rail-selection.png: slim-rail lift 110 185 350 295 · ribbon-rail lift 588 185 356 295 ·
//     glass-strip lift 1066 185 360 295 · graphic-sprite flood 112 615 336 245 (with template) ·
//     warm-studio lift 588 610 350 270 · paper-sprite lift 1066 610 355 270
//   menusprite-logo-flat.png: arranger-flat flood 100 200 1054 800 (with template)
// Templates from 3D renders were blotchy and are not bundled. Spec: docs/menu-bar-icon.md.
import AppKit
import CoreImage
import Vision

// usage: cut <mode flood|lift|lum> <src> <x> <y> <w> <h> <out> [templateOut]
let a = CommandLine.arguments
let mode = a[1], src = a[2]
let rect = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)
let out = a[7]; let templateOut = a.count > 8 ? a[8] : nil
let maxSide = 192.0

func load(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
struct Bitmap {
    var w: Int, h: Int, px: [UInt8] // RGBA, non-premultiplied
    init(_ img: CGImage) {
        w = img.width; h = img.height; px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) where px[i+3] > 0 && px[i+3] < 255 {
            let al = Double(px[i+3]) / 255
            for c in 0..<3 { px[i+c] = UInt8(min(255, Double(px[i+c]) / al)) }
        }
    }
    init(w: Int, h: Int) { self.w = w; self.h = h; px = [UInt8](repeating: 0, count: w * h * 4) }
    func image() -> CGImage {
        var pm = px
        for i in stride(from: 0, to: pm.count, by: 4) {
            let al = Double(pm[i+3]) / 255
            for c in 0..<3 { pm[i+c] = UInt8(Double(pm[i+c]) * al) }
        }
        let ctx = CGContext(data: &pm, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
func smooth(_ x: Double, _ lo: Double, _ hi: Double) -> Double { max(0, min(1, (x - lo) / (hi - lo))) }
func dist(_ b: Bitmap, _ i: Int, _ c: (Double, Double, Double)) -> Double {
    let r = Double(b.px[i]) - c.0, g = Double(b.px[i+1]) - c.1, bl = Double(b.px[i+2]) - c.2
    return (r*r + g*g + bl*bl).squareRoot()
}

var crop = Bitmap(load(src).cropping(to: rect)!)
var color = crop
switch mode {
case "flood", "lum":
    // Background = the crop's top-left pixel; flood from the border through background-ish pixels.
    let bg = (Double(crop.px[0]), Double(crop.px[1]), Double(crop.px[2]))
    let hi = 70.0, lo = 10.0
    var region = [Bool](repeating: false, count: crop.w * crop.h)
    var stack: [Int] = []
    for x in 0..<crop.w { stack.append(x); stack.append((crop.h - 1) * crop.w + x) }
    for y in 0..<crop.h { stack.append(y * crop.w); stack.append(y * crop.w + crop.w - 1) }
    while let p = stack.popLast() {
        if region[p] || dist(crop, p * 4, bg) > hi { continue }
        region[p] = true
        let x = p % crop.w, y = p / crop.w
        if x > 0 { stack.append(p - 1) }; if x < crop.w - 1 { stack.append(p + 1) }
        if y > 0 { stack.append(p - crop.w) }; if y < crop.h - 1 { stack.append(p + crop.w) }
    }
    for p in 0..<(crop.w * crop.h) where region[p] {
        let i = p * 4, al = smooth(dist(crop, i, bg), lo, hi)
        color.px[i+3] = UInt8(al * 255)
        if al > 0 { for (c, v) in [bg.0, bg.1, bg.2].enumerated() { color.px[i+c] = UInt8(max(0, min(255, (Double(crop.px[i+c]) - (1 - al) * v) / al))) } }
    }
case "lift":
    let handler = VNImageRequestHandler(cgImage: crop.image())
    let req = VNGenerateForegroundInstanceMaskRequest()
    try! handler.perform([req])
    let obs = req.results!.first!
    let buf = try! obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
    let ci = CIImage(cvPixelBuffer: buf)
    color = Bitmap(CIContext().createCGImage(ci, from: ci.extent)!)
    // The mask drops pale enclosed parts (eyes, pills) that resemble the card; anything transparent
    // that the outside cannot reach through transparent pixels is a hole, so put the original back.
    var outside = [Bool](repeating: false, count: color.w * color.h)
    var stack: [Int] = []
    for x in 0..<color.w { stack.append(x); stack.append((color.h - 1) * color.w + x) }
    for y in 0..<color.h { stack.append(y * color.w); stack.append(y * color.w + color.w - 1) }
    while let p = stack.popLast() {
        if outside[p] || color.px[p * 4 + 3] > 200 { continue }
        outside[p] = true
        let x = p % color.w, y = p / color.w
        if x > 0 { stack.append(p - 1) }; if x < color.w - 1 { stack.append(p + 1) }
        if y > 0 { stack.append(p - color.w) }; if y < color.h - 1 { stack.append(p + color.w) }
    }
    for p in 0..<(color.w * color.h) where !outside[p] && color.px[p * 4 + 3] < 255 {
        for c in 0..<3 { color.px[p * 4 + c] = crop.px[p * 4 + c] }; color.px[p * 4 + 3] = 255
    }
default: fatalError()
}

// Template: black, opaque where the art is opaque and not near-white (eyes and highlights become holes).
var template = color
for i in stride(from: 0, to: template.px.count, by: 4) {
    let al = Double(color.px[i+3]) / 255
    let ink: Double
    if mode == "lum" { // light art on a dark ground: brightness is the ink
        let lum = (0.299 * Double(crop.px[i]) + 0.587 * Double(crop.px[i+1]) + 0.114 * Double(crop.px[i+2]))
        ink = smooth(lum, 70, 200)
    } else { ink = smooth(dist(color, i, (255, 255, 255)), 45, 110) }
    template.px[i] = 0; template.px[i+1] = 0; template.px[i+2] = 0
    template.px[i+3] = UInt8((mode == "lum" ? ink : al * ink) * 255)
}
if mode == "lum" { color = template }

// Trim both to the colour art's opaque bounds, then scale so the longer side is maxSide.
func bounds(_ b: Bitmap) -> CGRect {
    var minX = b.w, minY = b.h, maxX = -1, maxY = -1
    for y in 0..<b.h { for x in 0..<b.w where b.px[(y * b.w + x) * 4 + 3] > 12 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
let box = bounds(color)
func write(_ b: Bitmap, _ path: String) {
    let trimmed = b.image().cropping(to: box)!
    let scale = min(1, maxSide / Double(max(trimmed.width, trimmed.height)))
    let w = Int((Double(trimmed.width) * scale).rounded()), h = Int((Double(trimmed.height) * scale).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(trimmed, in: CGRect(x: 0, y: 0, width: w, height: h))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    print(path, w, h)
}
write(color, out)
if let templateOut { write(template, templateOut) }
