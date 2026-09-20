import CoreGraphics
import SwiftUI

// ============================== DEV-SCOPE ==============================
// The density trace under the stage.
//
// The idiom is the reference scanner's own CCD Data Display (service manual
// 0343): black ground, hairline trace, one cursor, nothing else in the plot
// area. What it drops is everything around that -- grid, axis numbers, cursor
// readouts, frame. A histogram is a SHAPE, legible without a single label.
//
// It reads the RENDERED PREVIEW, not the master, so it is by construction what
// is on screen.
//
// TO REMOVE: grep DEV-SCOPE. Spread across five files now -- this one, the
// `scopes`/`parade` properties and the scope mode on the store, the rows in
// ContentView, `midGreyFraction` on Master and the CLI's scope flags -- so treat
// the grep as the list rather than trusting a count.
// =======================================================================

/// 256 bins per channel, already normalised to 0...1 for drawing.
struct Scopes: Equatable {
    var r: [Float]
    var g: [Float]
    var b: [Float]
    /// Where the frame's own exposure anchor lands, 0...1 across the axis.
    var anchor: Double

    /// Bin the rendered 8-bit preview.
    ///
    /// From the preview and not the master on purpose: this has to agree with the
    /// picture beside it, and the only way to guarantee that is to measure the
    /// same pixels the eye is looking at.
    ///
    /// Counts are square-rooted. A linear count is useless on a photograph --
    /// one sky tone owns the frame and everything else is a flat line along the
    /// bottom. The root keeps the small populations visible, which is the whole
    /// reason to look at this.
    /// `mask` is in the image's own coordinates, already rotated to match.
    static func of(_ img: CGImage, mask: Invert.Border?, anchor: Double) -> Scopes? {
        guard img.bitsPerComponent == 8, img.bitsPerPixel == 24,
              let data = img.dataProvider?.data as Data? else { return nil }
        var hr = [Int](repeating: 0, count: 256)
        var hg = hr, hb = hr
        let w = img.width, h = img.height, stride = img.bytesPerRow
        // Inside the frame only: the rebate's spike at code 0 is tall enough to
        // flatten the whole picture against the baseline.
        let (x0, x1, y0, y1) = (mask ?? .init()).inner(w: w, h: h)
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            // Every 2nd pixel of every 2nd row: a quarter of the samples puts the
            // shape within a pixel of the full count and keeps this off the
            // redraw budget.
            for y in Swift.stride(from: y0, to: y1, by: 2) {
                let row = p + y * stride
                for x in Swift.stride(from: x0 * 3, to: x1 * 3, by: 6) {
                    hr[Int(row[x])] += 1
                    hg[Int(row[x + 1])] += 1
                    hb[Int(row[x + 2])] += 1
                }
            }
        }
        // One shared scale, so the three traces stay comparable to each other.
        let peak = max(hr.max() ?? 1, max(hg.max() ?? 1, hb.max() ?? 1))
        guard peak > 0 else { return nil }
        let k = 1.0 / Float(peak).squareRoot()
        func norm(_ v: [Int]) -> [Float] { v.map { Float($0).squareRoot() * k } }
        return Scopes(r: norm(hr), g: norm(hg), b: norm(hb), anchor: anchor)
    }
}

/// An RGB parade: the three channels side by side, each column of the frame
/// plotted as a vertical smear of the values it contains.
///
/// What it shows that a histogram cannot is WHERE. A histogram says a frame has
/// blocked shadows; a parade says they are all down the left edge. And because
/// the three panels share one vertical scale, a cast reads as one channel simply
/// sitting higher than the others across the whole width -- which is the fastest
/// way there is to see it.
///
/// Pre-rendered as a single image: three 96-wide panels in one 288x96 bitmap, so
/// the whole thing is one draw call rather than 27648 cells.
struct Parade: Equatable {
    let image: CGImage
    /// 4x the cells of the first version, and every pixel sampled rather than
    /// one in four. The blotchiness was not cell SIZE, it was counting noise:
    /// 96x96x3 cells fed from a quarter of the pixels averages nine samples a
    /// cell, and nine is visibly Poisson. This is ~28 a cell at four times the
    /// resolution.
    static let cellsX = 192, cellsY = 192

    static func of(_ img: CGImage, mask: Invert.Border?) -> Parade? {
        guard img.bitsPerComponent == 8, img.bitsPerPixel == 24,
              let data = img.dataProvider?.data as Data? else { return nil }
        let gx = cellsX, gy = cellsY
        var acc = [UInt32](repeating: 0, count: gx * gy * 3)
        let w = img.width, h = img.height, stride = img.bytesPerRow
        let (x0, x1, y0, y1) = (mask ?? .init()).inner(w: w, h: h)
        let span = max(1, x1 - x0)
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in y0..<y1 {
                let row = p + y * stride
                for x in x0..<x1 {
                    let cx = (x - x0) * gx / span
                    let o = x * 3
                    for c in 0..<3 {
                        let v = Int(row[o + c]) * (gy - 1) / 255
                        acc[(c * gy + (gy - 1 - v)) * gx + cx] += 1
                    }
                }
            }
        }
        // Smooth ALONG THE VALUE AXIS only. The value axis is continuous -- a
        // tone either side of a bin is the same tone -- so a 1-2-1 there removes
        // the counting noise without touching real structure. Across the column
        // axis it would be a lie: neighbouring columns are different places in
        // the picture and must not bleed into each other.
        var sm = acc
        for c in 0..<3 {
            for x in 0..<gx {
                for y in 1..<(gy - 1) {
                    let o = (c * gy + y) * gx + x
                    sm[o] = (acc[o - gx] + 2 * acc[o] + acc[o + gx]) / 4
                }
            }
        }
        acc = sm
        // ONE scale across all three, so a channel sitting high is visible as
        // such. Per-channel normalisation would hide exactly the cast this is
        // best at showing.
        let peak = acc.max() ?? 0
        guard peak > 0 else { return nil }
        let k = 1.0 / Float(peak).squareRoot()
        let tint: [(Float, Float, Float)] = [(1.0, 0.35, 0.29), (0.33, 0.94, 0.48),
                                             (0.35, 0.66, 1.0)]
        var px = [UInt8](repeating: 0, count: gx * 3 * gy * 4)
        for c in 0..<3 {
            for y in 0..<gy {
                for x in 0..<gx {
                    let n = acc[(c * gy + y) * gx + x]
                    guard n > 0 else { continue }
                    let a = min(Float(n).squareRoot() * k * 2.6, 1)
                    let o = (y * (gx * 3) + c * gx + x) * 4
                    px[o] = UInt8(tint[c].0 * 255); px[o + 1] = UInt8(tint[c].1 * 255)
                    px[o + 2] = UInt8(tint[c].2 * 255); px[o + 3] = UInt8(a * 255)
                }
            }
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let out = CGImage(width: gx * 3, height: gy, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: gx * 3 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent) else { return nil }
        return Parade(image: out)
    }
}

/// The parade, on the same black ground as the trace. Two hairlines marking the
/// panel divisions, because without them the three channels read as one image.
struct ParadeView: View {
    let parade: Parade?
    var body: some View {
        ZStack {
            FUI.hex(0x0B0B0C)
            if let p = parade {
                Image(decorative: p.image, scale: 1).resizable()
                GeometryReader { geo in
                    Path { path in
                        for i in 1..<3 {
                            let x = geo.size.width * CGFloat(i) / 3
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                    }
                    .stroke(FUI.hex(0x0B0B0C), lineWidth: 2)
                }
            }
        }
        .overlay(Rectangle().strokeBorder(FUI.hex(0x3A3A3C), lineWidth: 1))
    }
}

/// The trace itself. Hairlines on black, and nothing else.
struct Scope: View {
    let scopes: Scopes?

    // Bright enough to read on black, and unmistakably R/G/B. The panel's own
    // inkRed/inkGreen/inkBlue are darkened for legibility on silver and go muddy
    // here, so these are their equivalents lifted for a black ground.
    private static let traceR = FUI.hex(0xFF5A4A)
    private static let traceG = FUI.hex(0x53F07A)
    private static let traceB = FUI.hex(0x5AA8FF)

    var body: some View {
        ZStack {
            FUI.hex(0x0B0B0C)                     // the machine's plot ground
            if let s = scopes {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    // The exposure anchor, drawn the way the machine draws its
                    // cursor: one vertical line, no handle, no readout.
                    Path { p in
                        let x = w * s.anchor
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                    trace(s.b, w: w, h: h).stroke(Self.traceB.opacity(0.9), lineWidth: 1)
                    trace(s.g, w: w, h: h).stroke(Self.traceG.opacity(0.9), lineWidth: 1)
                    trace(s.r, w: w, h: h).stroke(Self.traceR.opacity(0.9), lineWidth: 1)
                }
                .padding(.init(top: 5, leading: 2, bottom: 1, trailing: 2))
            }
        }
        // One hairline and nothing else. It floats on the white matte, so it
        // needs a boundary -- but a bevel here would read as a second panel, and
        // the whole point is that it is an instrument sitting ON the lightbox.
        .overlay(Rectangle().strokeBorder(FUI.hex(0x3A3A3C), lineWidth: 1))
    }

    /// One channel as a polyline along the bottom edge.
    private func trace(_ v: [Float], w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            guard v.count > 1 else { return }
            let dx = w / CGFloat(v.count - 1)
            p.move(to: CGPoint(x: 0, y: h))
            for (i, y) in v.enumerated() {
                p.addLine(to: CGPoint(x: CGFloat(i) * dx, y: h - CGFloat(y) * h))
            }
            p.addLine(to: CGPoint(x: w, y: h))
        }
    }
}
