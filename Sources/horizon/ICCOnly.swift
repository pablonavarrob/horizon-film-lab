import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ICC support: parsing an `mft2` A2B0 lookup, and rendering raw captures
// through a profile on its own.
//
// Two jobs use the `Transform` in here:
//
//  - `Paper.outputICC` -- the pipeline's terminator, in the same slot as a .cube
//    LUT: the levels stretch runs first and the profile supplies the transfer.
//    Where a profile built from positive scans belongs, and what the Print
//    Emulation menu loads.
//  - `--icc-only` below -- raw captures straight through a profile, no
//    inversion, no base, no stretch. Only correct for a profile built from RAW
//    NEGATIVES, which has the inversion baked in.
//
// `Transform.invertsTone` tells the two apart, and it matters: an emulation
// profile fed raw negatives renders a negative, sky dark and foliage pink.
enum ICCOnly {

    /// The A2B0 lookup of an `mft2` (16-bit) profile: three 1-D input curves,
    /// a cubic CLUT, three 1-D output curves.
    struct Transform {
        let grid: Int
        let inTable: [[Float]]      // 3 x n
        let clut: [Float]           // grid^3 * 3
        let outTable: [[Float]]     // 3 x m
        let name: String
        /// Device RGB straight to sRGB. The CLUT is used AS AUTHORED: Bradford
        /// D50 -> D65, sRGB matrix, then a per-channel clamp.
        ///
        /// Deliberately NOT media-relative white scaled, though that is what a
        /// colour-managed app is usually assumed to do. Wrong twice over: it
        /// lifts the whole midtone range to fix an endpoint (mean error against
        /// LittleCMS went 1.6 -> 5.8 code values, since LittleCMS only clips at
        /// the very top), and dividing raw XYZ by the profile white is not a
        /// chromatic adaptation at all -- this profile's white is XYZ (0.9417,
        /// 0.9625, 0.7838), already ~D50 as the spec requires, so scaling its Z
        /// to D65's 1.0890 applied a 1.389x BLUE LIFT to every pixel. The
        /// endpoint it was meant to fix (profile white lands on linear sRGB
        /// r = 1.0104, so red clips alone) belongs to the clamp below.
        func srgb(_ rgb: (Float, Float, Float)) -> (Float, Float, Float) {
            let (X, Y, Z) = apply(rgb)
            // Bradford D50 -> D65: the ICC PCS is D50, sRGB is D65.
            let x = 0.9555766 * X - 0.0230393 * Y + 0.0631636 * Z
            let y = -0.0282895 * X + 1.0099416 * Y + 0.0210077 * Z
            let z = 0.0122982 * X - 0.0204830 * Y + 1.3299098 * Z
            var r = 3.2406 * x - 1.5372 * y - 0.4986 * z
            var g = -0.9689 * x + 1.8758 * y + 0.0415 * z
            var b = 0.0557 * x - 0.2040 * y + 1.0570 * z

            // PER-CHANNEL CLAMP, because that is what the reference does.
            //
            // A luminance-preserving gamut map sat here instead, on the sound
            // reasoning that a per-channel clamp IS a hue shift. Audited against
            // TWO independent references -- littlecms relative colorimetric and
            // ColorSync via CoreGraphics -- over a 17^3 lattice plus a 256-step
            // neutral ramp. The references agree with each other to max 10 codes
            // / mean 0.12, the noise floor; ours against them:
            //
            //   gamut map            max 37  mean 1.21   dE76 max 15.2
            //   per-channel clamp    max  6  mean 0.24   dE76 mean 0.29
            //
            // The clamp lands INSIDE the reference noise floor and the map does
            // not. All twelve worst points were saturated yellow, blue lifted 33
            // to 37 codes too high, i.e. visibly desaturated. A 0.95 soft knee
            // cost more still: it rolls BEFORE the gamut surface, so IN-GAMUT
            // colour diverged by up to 12 codes.
            //
            // The pink highlights that motivated the map were real (7.3% of a
            // dusk sky pinned at R=255) but were measured while the ICC was fed
            // an RA-4 paper render, whose highlights sit near white so almost
            // everything clipped. It is now fed the levels-stretched master it
            // was built for. If they return, the fix is the input level.
            //
            // The same audit verified everything else here: the A2B0 parse, CLUT
            // axis order, trilinear interpolation, the u1Fixed15 scale (bit-
            // identical to lcms), both matrices and `srgbEncode`. The XYZ PCS
            // assumption is right -- the header says XYZ and the file carries
            // only an mft2 A2B0, no A2B1/A2B2/B2A and no TRCs.
            r = min(max(r, 0), 1)
            g = min(max(g, 0), 1)
            b = min(max(b, 0), 1)
            return (Paper.srgbEncode(r), Paper.srgbEncode(g), Paper.srgbEncode(b))
        }

        static func load(_ url: URL) throws -> Transform {
            let d = try Data(contentsOf: url)
            func u32(_ o: Int) -> Int {
                (Int(d[o]) << 24) | (Int(d[o+1]) << 16) | (Int(d[o+2]) << 8) | Int(d[o+3])
            }
            func u16(_ o: Int) -> Int { (Int(d[o]) << 8) | Int(d[o+1]) }
            guard d.count > 132 else { throw Err("\(url.lastPathComponent): too short for an ICC") }
            let tags = u32(128)
            var off = -1
            for i in 0..<tags {
                let p = 132 + i * 12
                guard p + 12 <= d.count else { break }
                if d[p] == 0x41, d[p+1] == 0x32, d[p+2] == 0x42, d[p+3] == 0x30 {   // "A2B0"
                    off = u32(p + 4)
                }
            }
            guard off > 0, off + 52 <= d.count else { throw Err("\(url.lastPathComponent): no A2B0 tag") }
            guard d[off] == 0x6D, d[off+1] == 0x66, d[off+2] == 0x74, d[off+3] == 0x32 else {
                throw Err("\(url.lastPathComponent): A2B0 is not mft2 (16-bit); only that form is handled")
            }
            let ins = Int(d[off + 8]), outs = Int(d[off + 9]), grid = Int(d[off + 10])
            guard ins == 3, outs == 3, grid > 1 else {
                throw Err("\(url.lastPathComponent): expected 3->3 with a CLUT")
            }
            // Validate BEFORE reading. `u16` subscripts Data directly, so a
            // truncated or hostile profile trapped -- the app died on open rather
            // than reporting an unreadable file.
            let n = u16(off + 48), m = u16(off + 50)
            guard n > 1, m > 1 else {
                throw Err("\(url.lastPathComponent): degenerate A2B0 curve tables")
            }
            guard off + 52 + 3 * n * 2 <= d.count else {
                throw Err("\(url.lastPathComponent): input curves truncated")
            }
            var p = off + 52
            func table(_ count: Int) -> [[Float]] {
                var t = [[Float]](repeating: [], count: 3)
                for c in 0..<3 {
                    t[c].reserveCapacity(count)
                    for k in 0..<count { t[c].append(Float(u16(p + (c * count + k) * 2)) / 65535) }
                }
                p += 3 * count * 2
                return t
            }
            let inT = table(n)
            let cells = grid * grid * grid * 3
            guard p + cells * 2 <= d.count else { throw Err("\(url.lastPathComponent): CLUT truncated") }
            var clut = [Float](); clut.reserveCapacity(cells)
            for k in 0..<cells { clut.append(Float(u16(p + k * 2)) / 65535) }
            p += cells * 2
            guard p + 3 * m * 2 <= d.count else {
                throw Err("\(url.lastPathComponent): output curves truncated")
            }
            let outT = table(m)
            return Transform(grid: grid, inTable: inT, clut: clut, outTable: outT,
                             name: url.deletingPathExtension().lastPathComponent)
        }

        /// Does this profile INVERT? Probed, not assumed, because it decides
        /// where the profile can legally go and the file does not say.
        ///
        /// A profile built from raw negatives has the inversion baked in, so its
        /// neutral ramp runs downhill: dark in, light out. One built from
        /// positive scans runs uphill. The colleague's minilab-emulation profile
        /// runs uphill (in 0.0 -> Y 0.001, in 1.0 -> Y 0.96), so it is an
        /// OUTPUT transform and rendering raw captures through it gives a
        /// negative with the sky dark and the foliage pink -- which is exactly
        /// what it did before this check existed.
        var invertsTone: Bool {
            let lo = apply((0.05, 0.05, 0.05)).1
            let hi = apply((0.95, 0.95, 0.95)).1
            return lo > hi
        }

        @inline(__always)
        private func curve(_ t: [Float], _ v: Float) -> Float {
            let x = min(max(v, 0), 1) * Float(t.count - 1)
            let i = min(Int(x), t.count - 2)
            return t[i] + (t[i + 1] - t[i]) * (x - Float(i))
        }

        /// Device RGB (0..1) -> PCS XYZ, D50, already scaled out of u1Fixed15.
        ///
        /// Scalars throughout, no arrays. This allocated three `[Float]`/`[Int]`
        /// buffers PER PIXEL, which cost 425 ms of a 1292x970 redraw against
        /// 40 ms for the whole rest of the render -- the same heap-per-pixel
        /// fault that the tone path had.
        func apply(_ rgb: (Float, Float, Float)) -> (Float, Float, Float) {
            let g = grid - 1
            let gf = Float(g)
            let xr = min(max(curve(inTable[0], rgb.0), 0), 1) * gf
            let xg = min(max(curve(inTable[1], rgb.1), 0), 1) * gf
            let xb = min(max(curve(inTable[2], rgb.2), 0), 1) * gf
            let ir = min(Int(xr), g - 1), ig = min(Int(xg), g - 1), ib = min(Int(xb), g - 1)
            let fr = xr - Float(ir), fg = xg - Float(ig), fb = xb - Float(ib)
            // ICC.1 lut16Type: "the first input channel varies least rapidly".
            // This once had R as the FASTEST axis, an exact R/B transposition --
            // the red stop sign came out purple and the blue sky orange. Neutrals
            // are unaffected by that swap, which is why it survived every
            // grey-ramp check and only showed on a real frame.
            let rowB = 3, rowG = grid * 3, rowR = grid * grid * 3
            let base = ir * rowR + ig * rowG + ib * rowB
            var a0: Float = 0, a1: Float = 0, a2: Float = 0
            clut.withUnsafeBufferPointer { c in
                for dr in 0..<2 {
                    let wr = dr == 0 ? 1 - fr : fr
                    if wr == 0 { continue }
                    for dg in 0..<2 {
                        let wrg = wr * (dg == 0 ? 1 - fg : fg)
                        if wrg == 0 { continue }
                        for db in 0..<2 {
                            let w = wrg * (db == 0 ? 1 - fb : fb)
                            if w == 0 { continue }
                            let o = base + dr * rowR + dg * rowG + db * rowB
                            a0 += w * c[o]; a1 += w * c[o + 1]; a2 += w * c[o + 2]
                        }
                    }
                }
            }
            // u1Fixed15: 0x8000 is 1.0, so the encoded range tops out at 65535/32768.
            let s: Float = 65535.0 / 32768.0
            return (curve(outTable[0], a0) * s,
                    curve(outTable[1], a1) * s,
                    curve(outTable[2], a2) * s)
        }
    }

    /// How to scale our captures into the profile's expected input range.
    ///
    /// The profile's input curves are 2-point identity, so it consumes linear
    /// values directly and is therefore tied to the capture exposure it was
    /// built for. Ours differs, which is why raw input rendered at p50 ~25.
    /// Neither normalisation is knowable from the file; both are tested.
    enum Scale: String {
        case none        // raw, as captured
        case global      // one factor, so the brightest channel's base -> 0.95;
                         // keeps the orange mask for the profile to remove
        case perChannel  // each channel's base -> 0.95; removes the mask first
    }

    /// One frame of RAW captures through the profile alone, as an image.
    ///
    /// Split out of `render` so the editor can put it on screen. Everything the
    /// profile needs is here; none of the operator's corrections apply, because
    /// this path deliberately does not touch our own rendering at all.
    static func image(frame urls: [URL], layout: Invert.Layout,
                      transform t: Transform, maxEdge: Int?,
                      scale: Scale = .global, quiet: Bool = false) throws -> CGImage {
        var (p, w, h) = try Invert.frame(urls, layout: layout)
        if let maxEdge, max(w, h) > maxEdge {
            let f = (max(w, h) + maxEdge - 1) / maxEdge
            let ow = w / f, oh = h / f
            var q = [[Float]](repeating: [Float](repeating: 0, count: ow * oh), count: 3)
            for c in 0..<3 {
                for y in 0..<oh {
                    for x in 0..<ow {
                        var s: Float = 0
                        for dy in 0..<f { for dx in 0..<f { s += p[c][(y * f + dy) * w + x * f + dx] } }
                        q[c][y * ow + x] = s / Float(f * f)
                    }
                }
            }
            p = q; w = ow; h = oh
        }
        if scale != .none {
            // Film base = the least dense part of the negative = the largest
            // transmittance. Take it per channel from the frame itself.
            let D = Invert.density(p, dark: nil, response: nil)
            let base = Invert.estimateBase(D, floor: 0.0)
            let t = base.map { powf(10, -Float($0)) }            // base transmittance
            let gains: [Float]
            switch scale {
            case .perChannel: gains = t.map { 0.95 / max($0, 1e-4) }
            default:          let g = 0.95 / max(t.max() ?? 1, 1e-4); gains = [g, g, g]
            }
            if !quiet {
                print(String(format: "  base T [%.3f %.3f %.3f]  gains [%.2f %.2f %.2f]",
                             t[0], t[1], t[2], gains[0], gains[1], gains[2]))
            }
            for c in 0..<3 {
                var g = gains[c]
                p[c].withUnsafeMutableBufferPointer { x in
                    vDSP_vsmul(x.baseAddress!, 1, &g, x.baseAddress!, 1, vDSP_Length(x.count))
                }
            }
        }
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let (r, g, b) = t.srgb((p[0][i], p[1][i], p[2][i]))
            px[i * 3] = UInt8(min(max(r * 255 + 0.5, 0), 255))
            px[i * 3 + 1] = UInt8(min(max(g * 255 + 0.5, 0), 255))
            px[i * 3 + 2] = UInt8(min(max(b * 255 + 0.5, 0), 255))
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24,
                                bytesPerRow: w * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { throw Err("cannot build image") }
        return img
    }

    /// 8-bit sRGB out of the profile, so PNG or JPEG and nothing else. This is
    /// deliberately not written as a 16-bit TIFF: it never had 16 bits in it.
    static func write(_ img: CGImage, to out: URL) throws {
        let type: UTType = out.pathExtension.lowercased() == "jpg" ? .jpeg : .png
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL,
                                                       type.identifier as CFString, 1, nil)
        else { throw Err("cannot write \(out.lastPathComponent)") }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { throw Err("write failed") }
    }

    /// One frame of RAW captures through the profile alone, to a file.
    static func render(frame urls: [URL], layout: Invert.Layout,
                       profile: URL, to out: URL, maxEdge: Int?,
                       scale: Scale = .global) throws {
        let t = try Transform.load(profile)
        let img = try image(frame: urls, layout: layout, transform: t,
                            maxEdge: maxEdge, scale: scale)
        try write(img, to: out)
        print("ICC-only: \(t.name)  \(t.grid)^3  ->  \(out.path)  \(img.width)x\(img.height)")
    }
}
