import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Cineon master on disk, plus the derived data the editor needs.
///
/// The master is never modified. Edits move the levels endpoints, fed through one
/// render function, so preview and export are the same code at two resolutions
/// -- which is also what the reference machine does: "image processing is
/// performed using the same print system", differing only in the terminal LUT
/// (F350/370 service manual).
struct Master: Sendable {
    let url: URL
    let width: Int, height: Int
    /// Planar 16-bit Cineon code, one array per channel.
    let planes: [[UInt16]]

    /// DEV-SCOPE — the frame rectangle at THIS master's scale. Already computed
    /// for the statistics; kept so the trace can exclude the rebate too.
    let frameMask: Invert.Border?

    /// The levels endpoints and this frame's LATD, MEASURED ONCE.
    ///
    /// It depends only on the pixels and the mask, both fixed at load -- but it
    /// was a method, and `render16` called it TWICE per redraw (once through
    /// `directLevels`, once through `autoGamma`), so every slider tick rebuilt
    /// the histogram twice against a ~6 ms budget.
    let ends: (lo: Double, hi: Double, latd: Double)

    /// The frame's LATD, as the tile readout. Now the number that actually
    /// places the exposure rather than a second statistic measured beside it.
    var autoLight: Double { ends.latd }

    // MARK: - Loading

    /// `frame` is the detected frame rectangle in FULL-RESOLUTION pixels. It
    /// masks the statistics only -- the pixels are never cropped, because the
    /// rebate is part of the picture as far as anyone printing borders is
    /// concerned, and because an imperfect detection must not be destructive.
    static func load(_ url: URL, maxEdge: Int? = nil,
                     frame: Invert.Border? = nil,
                     crop: Invert.Border? = nil) throws -> Master {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Err("cannot read \(url.lastPathComponent)")
        }
        guard img.bitsPerComponent == 16 else {
            throw Err("\(url.lastPathComponent) is \(img.bitsPerComponent)-bit; expected a 16-bit Cineon master")
        }

        // Read the raw bytes. Do NOT draw through a CGContext: Cineon codes are
        // DENSITY, not colour, and CoreGraphics would colour-manage them into
        // the destination space. Doing that read a median density of 0.073 where
        // the true value is 0.346 -- silently wrong, not obviously broken.
        let w = img.width, h = img.height
        guard let cfData = img.dataProvider?.data else { throw Err("no pixel data") }
        let raw = cfData as Data
        let comps = img.bitsPerPixel / 16
        guard comps >= 3 else { throw Err("expected >=3 components, got \(comps)") }
        let rowBytes = img.bytesPerRow
        guard raw.count >= rowBytes * h else { throw Err("short pixel buffer") }

        let bigEndian = img.byteOrderInfo == .order16Big
        // Crop window first, so nothing outside it is ever touched. Opt-in and
        // export-only: the default is the whole capture, rebate included.
        var cx = 0, cy = 0, cw = w, ch = h
        if let crop, !crop.isEmpty {
            let tw = w - crop.left - crop.right, th = h - crop.top - crop.bottom
            if tw > 16, th > 16, crop.left >= 0, crop.top >= 0, tw <= w, th <= h {
                cx = crop.left; cy = crop.top; cw = tw; ch = th
            }
        }
        let f = maxEdge.map { max(1, (max(cw, ch) + $0 - 1) / $0) } ?? 1
        let (planes, pw, ph) = readPlanes(raw, w: w, rowBytes: rowBytes, comps: comps,
                                          bigEndian: bigEndian,
                                          cx: cx, cy: cy, cw: cw, ch: ch, factor: f)

        // Scale the mask along with the pixels when previewing.
        var mask: Invert.Border? = nil
        if let frame, !frame.isEmpty, crop == nil {
            let f = w / max(pw, 1)
            mask = f > 1 ? Invert.Border(left: frame.left / f, top: frame.top / f,
                                        right: frame.right / f, bottom: frame.bottom / f)
                         : frame
        }
        return Master(url: url, width: pw, height: ph, planes: planes,
                      frameMask: mask,
                      ends: measureEnds(planes, width: pw, height: ph, mask: mask))
    }

    /// Deinterleave, crop and decimate in ONE parallel pass.
    ///
    /// This was three passes. A scalar triple loop turned 31 Mpx into three
    /// FULL-RESOLUTION planes -- 94 million nested-array subscripts, each paying
    /// a copy-on-write check and two bounds checks, with the endian test inside
    /// the innermost loop -- then a 180 MB allocation held the result, then a
    /// second complete pass box-averaged it down to preview size. For a preview
    /// every one of those full-resolution samples is read once and thrown away.
    ///
    /// Now the box sum accumulates as the rows are read, so the full-resolution
    /// planes never exist and the source is touched exactly once. Rows of the
    /// OUTPUT are independent, so it also parallelises cleanly.
    ///
    /// The decimation is still an exact box mean, which matters beyond speed:
    /// plain subsampling would alias grain into the median and move autoLight.
    private static func readPlanes(_ raw: Data, w: Int, rowBytes: Int, comps: Int,
                                  bigEndian: Bool,
                                  cx: Int, cy: Int, cw: Int, ch: Int,
                                  factor f: Int) -> ([[UInt16]], Int, Int) {
        let ow = cw / f, oh = ch / f
        let n = f * f
        var out = [[UInt16]](repeating: [UInt16](repeating: 0, count: ow * oh), count: 3)
        // f is at most 5 here, so f*f * 65535 stays well inside UInt32.
        out.withUnsafeMutableBufferPointer { pl in
            let p0 = pl[0].withUnsafeMutableBufferPointer { $0.baseAddress! }
            let p1 = pl[1].withUnsafeMutableBufferPointer { $0.baseAddress! }
            let p2 = pl[2].withUnsafeMutableBufferPointer { $0.baseAddress! }
            raw.withUnsafeBytes { buf in
                let base = buf.baseAddress!
                // One band per output row-block keeps each worker's writes
                // disjoint, so no locking and no false sharing worth caring about.
                let nBands = min(oh, max(1, ProcessInfo.processInfo.activeProcessorCount))
                let rowsPer = (oh + nBands - 1) / nBands
                DispatchQueue.concurrentPerform(iterations: nBands) { band in
                    let y0 = band * rowsPer, y1 = min(oh, y0 + rowsPer)
                    if y0 >= y1 { return }
                    for oy in y0..<y1 {
                        for ox in 0..<ow {
                            var s0: UInt32 = 0, s1: UInt32 = 0, s2: UInt32 = 0
                            for dy in 0..<f {
                                let row = base.advanced(by: (cy + oy * f + dy) * rowBytes)
                                    .assumingMemoryBound(to: UInt16.self)
                                var i = (cx + ox * f) * comps
                                for _ in 0..<f {
                                    if bigEndian {
                                        s0 += UInt32(row[i].byteSwapped)
                                        s1 += UInt32(row[i + 1].byteSwapped)
                                        s2 += UInt32(row[i + 2].byteSwapped)
                                    } else {
                                        s0 += UInt32(row[i]); s1 += UInt32(row[i + 1])
                                        s2 += UInt32(row[i + 2])
                                    }
                                    i += comps
                                }
                            }
                            let o = oy * ow + ox
                            p0[o] = UInt16(s0 / UInt32(n))
                            p1[o] = UInt16(s1 / UInt32(n))
                            p2[o] = UInt16(s2 / UInt32(n))
                        }
                    }
                }
            }
        }
        return (out, ow, oh)
    }


    // MARK: - Statistics

    /// The k-th smallest, in place, WITHOUT sorting. Quickselect with a
    /// median-of-three pivot.
    ///
    /// `sceneStats` used to get its median from a full sort of ~400 000
    /// doubles. A median needs a partition, not an order, and this returns
    /// bit-identical values to `sorted()[k]` -- the same element, in O(n).
    static func select(_ a: inout [Double], _ k: Int) -> Double {
        guard !a.isEmpty else { return 0 }
        var lo = 0, hi = a.count - 1
        let k = min(max(k, 0), a.count - 1)
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            // Median-of-three, so already-sorted input is not the worst case.
            if a[mid] < a[lo] { a.swapAt(mid, lo) }
            if a[hi] < a[lo] { a.swapAt(hi, lo) }
            if a[hi] < a[mid] { a.swapAt(hi, mid) }
            let pivot = a[mid]
            var i = lo, j = hi
            while i <= j {
                while a[i] < pivot { i += 1 }
                while a[j] > pivot { j -= 1 }
                if i <= j { a.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return a[k] }
        }
        return a[lo]
    }

    /// `select` is a hand-written partition, so prove it against `sorted()`.
    /// Returns the number of disagreements, which must be zero.
    static func checkSelect() -> (cases: Int, wrong: Int) {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {                        // xorshift, so it is repeatable
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 100_000) / 1000.0
        }
        var cases = 0, wrong = 0
        // Sizes around the even/odd boundary, plus the degenerate ones, plus
        // all-equal input which is where a naive partition loops forever.
        for n in [1, 2, 3, 4, 5, 17, 64, 65, 999, 1000, 4097] {
            for mode in 0..<3 {
                var a = (0..<n).map { i -> Double in
                    switch mode {
                    case 0: return rnd()
                    case 1: return 7.0                // all equal
                    default: return Double(n - i)     // reverse sorted
                    }
                }
                let want = a.sorted()
                for k in [0, n / 2, Int(0.5 * Double(n - 1)), n - 1] {
                    var copy = a
                    cases += 1
                    if select(&copy, k) != want[min(max(k, 0), n - 1)] { wrong += 1 }
                }
                a = []
            }
        }
        return (cases, wrong)
    }

    static func u16(_ v: Double) -> UInt16 {
        UInt16(min(max(v * 65535.0 + 0.5, 0), 65535))
    }

    /// DEV-LATD — transmittance of each histogram bin, 10^-D.
    ///
    /// A Frontier integrates TRANSMITTANCE, not density (Pako US4168120A: the
    /// LATD cell reads flux). That distinction is the whole robustness argument:
    /// in a negative a specular highlight is the DENSEST point, and 10^-D
    /// suppresses it, so a flux integral cannot be dragged by the outlier that
    /// drags a high percentile. Nothing needs to reject speculars because the
    /// operator itself is immune to them.
    ///
    /// 4096 entries, built once. Computing 10^-D per sample instead would be
    /// ~1.5 million `pow` calls per measurement; the histogram is already
    /// bucketed, so the bin is all the precision there is to have.
    static let binTransmittance: [Double] = (0..<4096).map { b in
        let code10 = (Double(b) / 4095.0) * Paper.maxCode
        return pow(10.0, -(code10 - Paper.codeOffset) / Paper.codeSlope)
    }

    // DEV-EXPRANGE, BUILT AND REMOVED, in four forms, all applying the histogram
    // stretch to the FINISHED render instead of the master. Recorded because the
    // conclusion is what matters: the midtone shortfall was never an exposure or
    // a levels problem, it is the PAPER CURVE, and nothing downstream of it can
    // undo it. Preview's stretch looks right because it works on the LOG MASTER,
    // where the midtone sits at 60% of the range; the paper curve has already
    // pushed it to 46%. Each form failed its own way -- neither paper span is
    // usable as a distance (the softplus white floor makes it ASYMPTOTE to 248,
    // so `whiteSpan` solves to 2.909 logE); shifting an anchor cannot fill a
    // range; and the rendering of a percentile is not the percentile of the
    // rendering, so a closed-form affine came out at gain 1.05.

    /// DEV-DIRECT — the levels endpoints, from the masked picture only.
    ///
    /// SHARED across the three channels, not per-channel. Prior art says four of
    /// five established tools use per-channel endpoints and call that the white
    /// balance; measured on both rolls it buys NOTHING here -- neutral-axis
    /// spread 3.04 shared vs 3.42 per-channel on roll A, 4.79 vs 4.03 on roll B,
    /// i.e. under 0.8 dE either way and each roll favours the opposite one. What
    /// per-channel does do is eat scene colour: on the sea-and-sky frame its
    /// white points disagree by 37% of span and it renders cream sky, teal water
    /// and orange rock, mean chroma 21.2 -> 12.6. Roll B's entire "improvement"
    /// was removing three genuinely orange sunset frames.
    ///
    /// AND NO AUTO WHITE BALANCE IS NEEDED. Each roll carries a roll-constant
    /// cast about the size of its own per-frame scatter, so a per-frame estimator
    /// cannot separate rig cast from scene colour -- and the profile's own
    /// non-neutrality largely cancels the device imbalance anyway: the
    /// near-neutral axis lands within ~2 Lab units of the profile's own neutral
    /// locus on both rolls. A per-channel printer-light AWB was built for the old
    /// print path and deleted: it never fed this one, so it corrected nothing.
    ///
    /// ENDPOINTS PLACE BLACK AND WHITE. THEY DO NOT PLACE MID-GREY.
    ///
    /// That separation is new and it is the point. The endpoints used to be chosen
    /// by where they left the MIDTONE, which is how p0.02/p99.98 was picked --
    /// scored against mid-grey at device code 95..102, where the profile puts L*50
    /// (verified independently: L*50 at code 95.0, gamma fit 1.987 over codes
    /// 32..224). Grey-world midtone by percentile pair, as measured then:
    ///
    ///            roll A   roll B
    ///   identity   98.6     77.4
    ///   0.02/99.98 104.3    93.2   <- chosen: "brackets the target, mean 100.1"
    ///   0.1 /99.9  112.1    98.0
    ///   0.5 /99.5  123.2   103.3
    ///
    /// KEPT BECAUSE IT IS THE RECORD OF A MISTAKE, and the ladder is still useful.
    /// The conclusion does not survive its own numbers: roll B reads 93.2, i.e.
    /// DARK, and it was averaged with roll A's 104.3 to claim the target was
    /// bracketed. Averaging two rigs that disagree is not evidence that either is
    /// right, and it is the pooling this project forbids everywhere else. Roll A no
    /// longer exists; the surviving roll's number was the one pointing at the
    /// defect, and "frames are usually too dark" is where it surfaced.
    ///
    /// Now the midtone has its OWN handle -- the levels midpoint, `autoGamma`,
    /// per frame -- so the endpoints are free to be correct on their own terms,
    /// which is where the histogram actually ends. See DEV-AUTOEXP.
    ///
    /// Still true, and now enforced properly: NO FIXED GAMMA. One constant cannot
    /// serve two rigs -- g=1.30 brings roll A's median to 98.3 and roll B's to
    /// 66.9. The rolls differ by a ~14 code offset no levels rule removes, roll B
    /// reading about 0.6 stop thinner, which is a per-rig base matter belonging to
    /// the inversion. A PER-FRAME midpoint is a different thing entirely: it is
    /// solved from each frame's own histogram, so it has no rig constant in it.
    /// After both changes the two current rolls sit 0.33 EV apart, down from 0.8.
    ///
    /// SHARED-vs-per-channel and the colour findings above are unaffected: the
    /// midpoint is channel-common, so it cannot move colour.
    ///
    /// STATIC, and called once from `load`. It reads only the pixels and the
    /// mask, both of which are fixed by the time a `Master` exists.
    static func measureEnds(_ planes: [[UInt16]], width: Int, height: Int,
                            mask frameMask: Invert.Border?)
        -> (lo: Double, hi: Double, latd: Double) {
        // MEASURED AT PREVIEW SCALE, whatever this master's resolution is.
        //
        // The endpoints are p0.02/p99.98, far enough into the tail that how much
        // the data has been smoothed decides where they land. Before this, one
        // frame measured span 0.619 in the preview (1224 px) and 0.781 in the
        // full-res export (4896 px) -- a 26% contrast difference between what the
        // operator approved and what got written, while `write` claimed to be
        // WYSIWYG. Decimating here with the SAME factor and the same box mean
        // `Master.load` uses makes the two agree by construction rather than by
        // a tuned kernel: at or below preview size f is 1 and nothing changes.
        let f = max(1, (max(width, height) + FrameItem.previewEdge - 1) / FrameItem.previewEdge)
        let src: [[UInt16]], w: Int, h: Int
        if f == 1 {
            src = planes; w = width; h = height
        } else {
            (src, w, h) = Master.boxMean(planes, w: width, h: height, factor: f)
        }
        let n = src[0].count
        var x0 = 0, x1 = w - 1, y0 = 0, y1 = h - 1
        if let m = frameMask, !m.isEmpty {
            // The mask is in native pixels; scale it into the measured grid.
            x0 = max(m.left / f, 0); y0 = max(m.top / f, 0)
            x1 = min(w - 1 - m.right / f, w - 1)
            y1 = min(h - 1 - m.bottom / f, h - 1)
        }
        // SHAVE, then blur. They do different jobs and the tight percentiles need
        // both: the shave rejects mask slop, the blur rejects grain and dust. On
        // one frame a 10 px shave moved the white endpoint by 20.8% of span --
        // unmasked frame edge just inside the stored border -- where the blur
        // moved it 0.3%. At p0.5/p99.5 neither mattered (about 1% of span); at
        // p0.02/p99.98 both do.
        let shave = max(8, Int(0.0025 * Double(min(w, h))))
        x0 += shave; y0 += shave; x1 -= shave; y1 -= shave
        guard x1 - x0 > 32, y1 - y0 > 32, n > 0 else { return (0, 1, 0.5) }

        var hist = [Int](repeating: 0, count: 4096)
        var count = 0
        let sx = max(1, (x1 - x0) / 700), sy = max(1, (y1 - y0) / 700)
        src[0].withUnsafeBufferPointer { p0 in
        src[1].withUnsafeBufferPointer { p1 in
        src[2].withUnsafeBufferPointer { p2 in
            let ch = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!]
            var y = y0 + 1
            while y <= y1 - 1 {
                var x = x0 + 1
                while x <= x1 - 1 {
                    for c in 0..<3 {
                        // 3x3 box average. A STRIDE SUBSAMPLE IS NOT A SUBSTITUTE:
                        // it does not reduce grain, and grain is exactly what
                        // moves an endpoint this far out in the tail.
                        var acc = 0
                        for dy in -1...1 {
                            let row = (y + dy) * w + x
                            acc += Int(ch[c][row - 1]) + Int(ch[c][row]) + Int(ch[c][row + 1])
                        }
                        let v = acc / 9
                        // Clipped pixels carry no level information. Without this
                        // the endpoint pinned at the floor or ceiling on 38 of 44
                        // frames and the stretch degenerated to the identity.
                        if v <= 0 || v >= 65535 { continue }
                        hist[v >> 4] += 1
                        count += 1
                    }
                    x += sx
                }
                y += sy
            }
        }}}
        guard count > 300 else { return (0, 1, 0.5) }
        func pct(_ q: Double) -> Double {
            let want = Int(q * Double(count)); var acc = 0
            for b in 0..<4096 { acc += hist[b]; if acc >= want { return Double(b) / 4095 } }
            return 1
        }
        // p0.02 / p99.98, i.e. where the histogram effectively ends.
        //
        // MEASURED AND NOT TAKEN: moving white to p99.5. The two ends are not the
        // same kind of thing -- film base is a hard floor, so the bottom tail is
        // bounded by physics, while speculars and the film shoulder run on
        // indefinitely at the top. Tail as a fraction of span, two rigs:
        //
        //                      bottom p0.02->p1    top p99->p99.98
        //   37-frame roll            4.9%              43.9%
        //   12-frame roll            3.6%              18.1%
        //
        // So p99.98 sits about 2.3 stops above p99.
        //
        // p99.5 WAS TRIED AND IS WORSE, once DEV-GATE is in. Measured over both
        // rolls through the roll gate, output spread and the exponent the
        // placement then demands:
        //
        //   p99.98   spread 2.28 EV   g 0.219..0.811   <- here
        //   p99.5    spread 3.42 EV   g 0.273..1.902
        //
        // p99.5 measured BETTER before the gate existed, which is what the old
        // note here recorded as "the next thing to try". It was reading around
        // the real defect: the frames whose white point ran away were the ones
        // measuring through the rebate, not the ones whose percentile was too
        // tight. With the rebate excluded the tight endpoint is the stable one,
        // and p99.5 starts demanding g > 1 on some frames, i.e. it darkens them.
        //
        // Support/knee detection was also built and lost outright: higher variance
        // than any percentile and an UNBOUNDED clip fraction (11.9% on one roll
        // against 9.2% on the other at the same setting).
        let lo = pct(0.0002), hi = pct(0.9998)
        guard hi > lo + 1e-4 else { return (0, 1, 0.5) }

        // DEV-LATD — the frame's Large Area Transmission Density, which is what
        // a photofinisher actually meters: integrate TRANSMITTANCE over the
        // frame, then take the density of the result. NOT a median of density,
        // which is what stood here (`pct(0.5)`) and what `sceneStats` measured
        // beside it. On the 12-frame roll the flux integral is half again as
        // stable across the roll: sd 0.078 against the median's 0.123.
        //
        // Returned in the SAME normalised units as the endpoints, so
        // `autoGamma` can take (latd - lo)/span directly. The density->normal
        // map is affine, so the ratio is identical either way round.
        var flux = 0.0
        for b in 0..<4096 where hist[b] != 0 {
            flux += Double(hist[b]) * Master.binTransmittance[b]
        }
        guard flux > 0 else { return (lo, hi, (lo + hi) / 2) }
        let latdD = -log10(flux / Double(count))
        let latd = (latdD * Paper.codeSlope + Paper.codeOffset) / Paper.maxCode
        return (lo, hi, latd)
    }

    /// Non-overlapping f x f box mean. The same reduction `readPlanes` applies
    /// when it decimates on load, so measuring a full-res master through this
    /// yields the very buffer the preview measured.
    static func boxMean(_ p: [[UInt16]], w: Int, h: Int, factor f: Int)
        -> ([[UInt16]], Int, Int) {
        let ow = w / f, oh = h / f
        guard ow > 0, oh > 0 else { return (p, w, h) }
        var out = [[UInt16]](repeating: [UInt16](repeating: 0, count: ow * oh), count: 3)
        let half = f * f / 2, area = f * f
        for c in 0..<3 {
            p[c].withUnsafeBufferPointer { srcB in
                let src = srcB.baseAddress!
                out[c].withUnsafeMutableBufferPointer { dstB in
                    let dst = dstB.baseAddress!
                    Master.bands(oh) { r0, r1 in
                        for oy in r0..<r1 {
                            for ox in 0..<ow {
                                var acc = 0
                                for dy in 0..<f {
                                    let row = (oy * f + dy) * w + ox * f
                                    for dx in 0..<f { acc += Int(src[row + dx]) }
                                }
                                dst[oy * ow + ox] = UInt16((acc + half) / area)
                            }
                        }
                    }
                }
            }
        }
        return (out, ow, oh)
    }

    // ============================== DEV-DIRECT ==============================
    // master -> per-frame levels -> ICC. No paper curve.
    //
    // The operator verified this by hand: open the cached master, drag the black
    // and white points to the histogram, apply the ICC, and it looks like a
    // minilab scan. Our app ran master -> RA-4 paper simulation -> ICC instead,
    // which DOUBLE-APPLIES a tone curve, because the profile was built from
    // "merged and inverted rgb scans" -- stretched masters, not paper renders.
    // That is why every attempt to fix the paper model made the result worse.
    //
    // The controls map onto the two endpoints, the same operation the operator
    // performs by hand, so each one means something obvious:
    //   Density        both endpoints together   (exposure)
    //   C / M / Y      one channel's endpoints   (colour balance)
    //   Contrast       the gap between them      (tighter stretch = more contrast)
    //   Highlight tone the WHITE point           (outward = highlights darker)
    //   Shadow tone    the BLACK point           (outward = blacks deeper)
    //
    // Density and C/M/Y move in the master's own density units, so the UI numbers
    // keep the meaning they have on a real machine: `densStep` is the published
    // 15% density key, `cmyStep` its 8% colour key.
    //
    // NOT REMOVABLE: this IS the pipeline now, not a flag on top of one. The
    // tag is kept only because the reasoning above is worth finding by grep.
    // =======================================================================

    /// DEV-SCOPE — where mid-grey lands on the output axis, 0...1, for the
    /// histogram's cursor. Mid of the stretched range through whichever
    /// terminator is active, so the hairline always marks the tone the pipeline
    /// actually renders mid-grey as.
    var midGreyFraction: Double {
        if let icc = Paper.outputICC {
            let o = icc.srgb((0.5, 0.5, 0.5)); return Double(o.1)
        }
        if let lut = Paper.printLUT {
            return Double(PrintLUT.toSRGB(lut.sample(0.5, 0.5, 0.5).1))
        }
        return Paper.transfer(Master.directExposure(0.5, span: Paper.directSpan), channel: 1)
    }

    /// Stretched value -> paper log exposure. The built-in terminator's only
    /// parameter, and its contrast control.
    ///
    /// The stretch hands over 0..1 where 0 is the frame's own darkest scene and
    /// 1 its brightest. On paper a dense negative passes less light, so v = 1 is
    /// LOW exposure and a light print.
    ///
    /// 1.4, not the 1.8 that maps the paper's whole published curve (logE
    /// -0.9..+0.9) onto the whole stretched range. 1.8 measured too punchy on
    /// sight, and the span is the one lever that moves punch: it scales both
    /// contrast and saturation together, so it calms the look without changing
    /// its character. Measured on a real frame, interquartile spread and mean
    /// chroma against the ICC's 83.3 / 15.2:
    ///
    ///   span 1.0   87.9 / 20.6   but black 19.0 and white 239 -- ends lost
    ///        1.2  100.7 / 22.7
    ///        1.4  111.3 / 24.0   <- here, black 12.0, white 247.7
    ///        1.6  120.7 / 25.4
    ///        1.8  129.7 / 26.6   (was here)
    ///
    /// Narrowing further reaches the ICC's contrast but goes milky at both ends
    /// before it reaches its saturation, so 1.0 is the floor and not a target.
    /// The operator's Contrast buttons move either side of this, so Normal now
    /// sits where Soft 2 used to and the old punch is still on Hard.
    @inline(__always)
    static func directExposure(_ v: Double, span: Double = Paper.directSpan) -> Double {
        Paper.midGreyLogE + (0.5 - v) * span
    }

    /// How far one tone press moves its endpoint, as a fraction of the span.
    /// How much one Tone Adjustment press changes its side's SLOPE, as a
    /// fraction. Hard+ (`gradeAmount` 2) is therefore 1.5x the slope and Soft+
    /// (-1.2 after `softDamp`) is 0.7x. It replaced `directToneStep = 0.10`,
    /// which moved an endpoint by 10% of the span per press -- see `toneSlopes`
    /// for why an endpoint is the wrong thing for this control to touch.
    static let directToneSlope = 0.25

    /// THE VALUE PATH, one channel, one sample: stretch, expose, shape, balance.
    ///
    /// `render16` folds exactly this into its 65536-entry table, and the gate
    /// sweeps it directly -- so the invariants it checks (monotone, in range, the
    /// aim pinned) are checked on the arithmetic that actually renders, not on a
    /// paraphrase of it. It replaced `levelSpan`, which measured the gap between
    /// the endpoints; that became meaningless once no control moved an endpoint.
    @inline(__always)
    static func curveValue(_ x: Double, lo: Double, hi: Double, gamma: Double,
                           aim: Double, slopes: (lo: Double, hi: Double),
                           offset: Double, shoulder: Bool = false) -> Double {
        var v = min(max((x - lo) / max(hi - lo, 1e-4), 0), 1)
        if gamma != 1 { v = pow(v, gamma) }
        v = tone(v, aim: aim, lo: slopes.lo, hi: slopes.hi, shoulder: shoulder)
        return min(max(v + offset, 0), 1)
    }



    // ================== AUTO EXPOSURE (DEV-AUTOEXP) ==================
    // TO REMOVE: this comment block, `outLinear`, `aimValue`, `Terminator.aim`,
    // `autoGamma`, the `ag`/`curve` table in `render16` (restore the inline
    // gain-offset-clamp), `Paper.printAim`, and `binTransmittance` with the LATD
    // block at the end of `measureEnds` (restore `pct(0.5)` as the third return).
    //
    // LATD placement, which is what a photofinisher does: measure the frame's
    // integrated density and set the print so it lands on the aim. No grey-world,
    // and -- see below -- no colour decision of any kind.
    //
    // It is the levels MIDPOINT, not a window shift. Levels has three handles and
    // only two were being used. Translating the window was tried first and lifts
    // the black, because the terminator's domain IS the stretched range: an ICC
    // built from stretched masters has no headroom below 0, so a shifted window
    // renders the frame's darkest scene value at code 18 instead of 0. Measured
    // over both rolls, black point:
    //
    //            markesteijn   new-captures
    //   endpoints only   2.4          3.8
    //   window shift     8.6         17.8      <- fade, and visibly so
    //
    // That fade is the exact failure the levels-then-profile architecture exists
    // to avoid, so the window is left alone and the midpoint carries the whole
    // correction. Black stays black, white stays white, end contrast untouched.
    //
    // Second reason it is the right handle: the same gamma applies to all three
    // channels, so a neutral input stays neutral -- auto exposure cannot shift
    // colour even in principle. A window shift could not claim that. The
    // terminator's neutral axis is curved (a neutral comes out of the ICC with
    // R-B running -6 to +20 codes across the range), so translating a midtone
    // along it swung the frame up to 4.8 keys blue-ward. Four separate attempts
    // to cancel that all measured worse than not moving. Curvature only bites a
    // translation; v^gamma pins both ends, where the axis is anchored.

    /// The terminator evaluated on ONE stretched triple, in LINEAR light.
    /// Deliberately mirrors the inner loop of `render16` -- it is the same three
    /// branches. If that loop changes, this changes with it.
    /// Takes the two terminator slots rather than a `Terminator`, because
    /// `Terminator.init` calls this to solve its own `aim`.
    static func outLinear(_ v: (Double, Double, Double),
                          icc: ICCOnly.Transform?, lut: PrintLUT?,
                          span: Double)
        -> (Double, Double, Double) {
        let r = Float(min(max(v.0, 0), 1))
        let g = Float(min(max(v.1, 0), 1))
        let b = Float(min(max(v.2, 0), 1))
        var o: (Float, Float, Float)
        if let icc { o = icc.srgb((r, g, b)) }
        else if let lut {
            let s = lut.sample(r, g, b)
            o = (PrintLUT.toSRGB(s.0), PrintLUT.toSRGB(s.1), PrintLUT.toSRGB(s.2))
        } else {
            o = (Float(Paper.transfer(directExposure(Double(r), span: span), channel: 0)),
                 Float(Paper.transfer(directExposure(Double(g), span: span), channel: 1)),
                 Float(Paper.transfer(directExposure(Double(b), span: span), channel: 2)))
        }
        return (Paper.srgbDecode(Double(o.0)), Paper.srgbDecode(Double(o.1)),
                Paper.srgbDecode(Double(o.2)))
    }

    /// Stretched value whose terminator output luminance is `Paper.printAim`.
    /// Bisection, because the aim has to be solved against whichever terminator
    /// is loaded rather than hardcoded -- the ICC, a .cube and the RA-4 curve put
    /// the aim in three different places. Monotone in v for all three.
    static func aimValue(icc: ICCOnly.Transform?, lut: PrintLUT?,
                         span: Double) -> Double {
        func lum(_ v: Double) -> Double {
            let o = outLinear((v, v, v), icc: icc, lut: lut, span: span)
            return Paper.lumaW.0 * o.0 + Paper.lumaW.1 * o.1 + Paper.lumaW.2 * o.2
        }
        var lo = 0.02, hi = 0.98
        for _ in 0..<26 {
            let m = (lo + hi) / 2
            if lum(m) < Paper.printAim { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    /// The exponent on the stretched value that puts this frame's LATD on the aim.
    /// Closed form: v^g = aim, so g = ln(aim)/ln(v). 1.0 is no correction.
    ///
    /// FULL CORRECTION, AND NO LIMITER. There was a clamp here
    /// (`Paper.autoGammaMin` = 0.70) whose documented justification was that it
    /// "touched exactly ONE frame of the 49". Measured on the DEFAULT terminator
    /// -- the built-in RA-4 curve, which is what the app boots on -- it bound on
    /// 43 OF 49: this aim solves to v 0.4993 there, frames' LATD sits near 0.27,
    /// so the placement wants g around 0.52 and was allowed only 0.70. That was
    /// the whole of the -1.5 EV "previews are too dark". The old figure was
    /// measured through the ICC, where the profile's own curve does the lifting
    /// and g stays inside the bound, and was never re-checked on the other path.
    ///
    /// It should not come back in any form, because LIFTING IS THE BEHAVIOUR. A
    /// minilab places every frame on its aim; that is why a print of a candlelit
    /// room comes back brighter than the room looked. "A dark scene keeps its
    /// darkness" is a photographer's preference, not a photofinisher's, and the
    /// per-frame Density key is where it belongs.
    ///
    /// TRIED AND MEASURED WORSE, so do not re-derive them:
    ///   - Partial correction, g = 1 + S(g_full - 1), the Pako slope a real
    ///     LATD printer uses to attenuate subject failure. Swept S = 0..1 over
    ///     both rolls: median AND spread degrade monotonically as S falls.
    ///     S = 1 is right here. ponytail: S is the upgrade path if a roll ever
    ///     over-corrects, and it beats a clamp because it has no threshold --
    ///     every frame is treated alike and nothing is discontinuous.
    ///   - Dmax as an "underexposed vs genuinely dark" discriminator, to correct
    ///     only the former. corr(g, Dmax) is +0.17 on one roll and -0.59 on the
    ///     other, OPPOSITE SIGNS; two frames at Dmax 0.566 and 0.623 demand
    ///     g 0.811 and 0.219. It does not separate them, and it is rig-dependent.
    ///
    /// What remains are validity guards, not bounds on the correction: `v` held
    /// off 0 and 1 so `log(v)` exists, and a finite check.
    ///
    /// SOLVED AGAINST THE ENDPOINTS IT IS APPLIED TO. It used to read the
    /// UNEDITED endpoints while `render16` applied it to the EDITED stretch, so
    /// every manual correction was graded by an exponent solved for a different
    /// window. On a thin frame that is not subtle -- DSCF1577 meters at v 0.0486
    /// of its own span, and one press of Contrast Hard 1 moved the black point
    /// to v -0.0051, i.e. PAST the metered point, while the exponent still
    /// assumed the old window. That is what "the blacks break everything" was.
    /// The old limiter hid it: at g >= 0.70 the mismatch stayed mild.
    ///
    /// `edit.density` MOVES THE AIM, which is the one actuator that neither
    /// clips nor collapses. It is the same key a machine has -- printer exposure
    /// -- and `Paper.densStep` is its published 15% step, so the metered point is
    /// placed on `aim / 1.15^density` instead of on `aim`. Exact by construction,
    /// monotonic, and both endpoints stay pinned, so the contrast the operator
    /// set survives a density press.
    ///
    /// TWO WORSE ACTUATORS, BOTH MEASURED. Output p10..p90 in 8-bit codes on a
    /// normal frame, against 189 at D0:
    ///
    ///                       D-6    D-3    D+3    D+6
    ///   window translation   34    132    103     11     clips at 0/1
    ///   bias the metered D   76    123     95      3     `g` explodes as v->1
    ///   move the aim (here)  see the gate; no collapse at either end
    ///
    /// Translating the window preserves the span in master units but slides the
    /// picture into the hard clamp, so six presses of Darker cost 94% of the
    /// contrast. Biasing the LATD instead re-solves `g` from a point pushed
    /// toward the white end, where `g = ln(aim)/ln(v)` grows without bound --
    /// v 0.30 -> 0.70 takes g from 0.87 to 2.9 and crushes the frame to black.
    ///
    /// A gamma DOES reshape the tone scale as it exposes; that is inherent. The
    /// alternative that preserves the shape exactly is a translation, and the
    /// terminator has no headroom below 0 for one (see DEV-AUTOEXP above). Given
    /// that, never clipping is the better trade.
    ///
    /// C/M/Y stay on the endpoints, per channel, because they are colour and not
    /// exposure.
    /// SOLVED AGAINST THE FRAME'S OWN ENDPOINTS, NOT THE OPERATOR'S.
    ///
    /// There used to be a `gradedEnds` here that folded the tone controls into
    /// the endpoints first, plus a guard keeping the metered point inside them.
    /// Both are gone: the tone controls no longer touch the endpoints at all
    /// (`toneSlopes`), so there is nothing to fold and nothing to guard. Exposure
    /// depends only on the frame, which is what makes it independent of contrast.
    func autoGamma(_ term: Terminator, _ edit: Edit) -> Double {
        let span = max(ends.hi - ends.lo, 1e-4)
        let v = min(max((ends.latd - ends.lo) / span, 0.02), 0.98)
        let g = log(Master.aimTarget(term, edit)) / log(v)
        return g.isFinite && g > 0 ? g : 1
    }

    /// Where the metered point is asked to land: the terminator's aim, offset by
    /// the operator's density key at the published 15% per press. Held inside
    /// (0,1) because it is a value in the stretched domain -- that is a domain
    /// guard, not a bound on the correction.
    static func aimTarget(_ term: Terminator, _ edit: Edit) -> Double {
        let aim = min(max(term.aim, 0.02), 0.98)
        let t = aim * pow(10.0, -Double(edit.density) * Paper.densStep)
        return min(max(t, 1e-4), 0.999)
    }

    /// The levels endpoints after the operator's controls, per channel.
    /// Normalised master units, i.e. 16-bit code / 65535. Auto exposure is NOT
    /// here -- it is the midpoint, which by definition leaves both endpoints
    /// alone, so the histogram overlay that draws these stays truthful.
    func directLevels(_ edit: Edit) -> (lo: [Double], hi: [Double]) {
        // The frame's own endpoints, the same for all three channels. No control
        // moves them any more, so the histogram overlay drawn from this is simply
        // the truth about the stretch.
        ([ends.lo, ends.lo, ends.lo], [ends.hi, ends.hi, ends.hi])
    }

    /// A colour key in the master's normalised domain: the master IS density in
    /// Cineon code, so one key is codeSlope/maxCode of its log step. There is no
    /// density equivalent any more -- density moves the aim, see `autoGamma`.
    static let cmyUnit = Paper.cmyStep * Paper.codeSlope / Paper.maxCode

    /// C/M/Y as a PRINTER LIGHT: a per-channel offset applied AFTER exposure and
    /// contrast, so it shifts every tone by the same amount.
    ///
    /// It used to be an offset on the per-channel ENDPOINTS, which put it upstream
    /// of the exposure exponent and of the 0/1 clamp -- so a colour key did wildly
    /// different things at different tones. Measured, +6 magenta on the green
    /// channel of a normal frame:
    ///
    ///   shadows    -20.6 codes   0.25x
    ///   midtones   -81.9 codes   1.00x
    ///   highlights -93.2 codes   1.14x
    ///
    /// Deep shadows sat at v ~ 0 already, so the offset was simply eaten by the
    /// clamp; midtones took it in full. Applied after the exponent it is a
    /// constant shift in the value the terminator consumes, and for the built-in
    /// curve `directExposure` maps that linearly to log exposure -- which is
    /// exactly what a printer light is on the real machine.
    ///
    /// Sign: + is more of that ink, i.e. LESS of its channel, matching the
    /// "+ Cyan / - Red" labelling on the panel.
    static func cmyOffsets(_ edit: Edit) -> (Double, Double, Double) {
        let u = cmyUnit
        return (-Double(edit.cyan) * u, -Double(edit.magenta) * u,
                -Double(edit.yellow) * u)
    }

    /// The channel-common endpoints after the controls that shape TONE.
    ///
    /// DENSITY IS NOT HERE ANY MORE, and that is the point. It used to translate
    /// the whole window (`lo += d; hi += d`), which preserves the span in master
    /// units but slides the picture into the hard clamp at 0/1 -- so it CLIPPED
    /// rather than exposed. Measured on a normal frame, output p10..p90 in 8-bit
    /// codes: D-6 34.2, D-3 131.5, D0 189.3, D+3 103.0, D+6 10.9. Pressing
    /// Darker six times threw away 94% of the contrast.
    ///
    /// Density is now a bias on the METERED LATD instead (see `autoGamma`),
    /// which is what the key does on a real machine: it offsets the exposure the
    /// meter asks for. Both endpoints stay put, so the contrast the operator set
    /// survives a density press exactly, and nothing can clip.
    ///
    /// CONTRAST IS A SLOPE ABOUT THE AIM, NOT A MOVE OF THE ENDPOINTS.
    ///
    /// This is the fix for "the tone adjustments just crush everything". Tone used
    /// to move an endpoint by a fraction of the span, and then `autoGamma`
    /// re-solved the exposure against the moved endpoints -- so the two FOUGHT.
    /// Press Hard, the black point rises, the exposure sees its metered point
    /// sitting lower in the range and lifts harder to compensate, cancelling the
    /// press. Measured on a thin frame, output p10..p90 in 8-bit codes:
    ///
    ///   Hard 1       135.4    Hard 2        135.8   <- identical, no range left
    ///   Shadow Hard  135.0    Shadow Hard+  135.0   <- identical
    ///   Normal        48.3    Soft 3         12.1   <- and soft collapsed instead
    ///
    /// Now exposure decides WHERE the metered point lands and contrast decides the
    /// SLOPE THROUGH IT. Neither can undo the other, because the pivot is the aim:
    /// `aim + (v - aim) * k` leaves v = aim fixed for every k. Applied after the
    /// exposure exponent, still in the stretched domain and still upstream of the
    /// terminator -- DEV-EXPRANGE's finding is about stretching the FINISHED
    /// render, which this is not.
    ///
    /// Two slopes, because Highlight and Shadow are separate controls on the real
    /// machine: `hi` acts above the aim, `lo` below it. Gradation Selection is the
    /// main gradation and moves both.
    static func toneSlopes(_ edit: Edit,
                           newCurve: Bool = false) -> (lo: Double, hi: Double) {
        let base = (1 + Paper.gradationStep * Double(min(max(edit.gradation,
                                                        Paper.gradationRange.0),
                                                    Paper.gradationRange.1)))
        func side(_ g: Paper.Grade) -> Double {
            max(base * (1 + directToneSlope * Paper.gradeAmount(g)), 0.05)
        }
        return (lo: side(edit.shadow), hi: side(edit.high))
    }

    /// A two-sided slope about the aim. Monotone, and it pins the aim exactly.
    ///
    /// `shoulder` is DEV-DRANGE: instead of clamping at 0 and 1, roll off
    /// asymptotically outside a knee placed part-way from the aim to each end.
    /// The inner band is untouched, so the aim stays pinned however hard the slope
    /// is, and nothing ever reaches 0 or 1 -- which is the point. Paper never
    /// reaches either end either; `Paper.paperDensity` already approaches white
    /// through a softplus for the same reason.
    @inline(__always)
    static func tone(_ v: Double, aim: Double, lo kLo: Double, hi kHi: Double,
                     shoulder: Bool = false) -> Double {
        let s = aim + (v - aim) * (v > aim ? kHi : kLo)
        guard shoulder else { return min(max(s, 0), 1) }
        let hiK = aim + Paper.kneeHigh * (1 - aim)
        let loK = aim - Paper.kneeLow * aim
        if s > hiK, hiK < 1 { return hiK + (1 - hiK) * (1 - exp(-(s - hiK) / (1 - hiK))) }
        if s < loK, loK > 0 { return loK * exp((s - loK) / loK) }
        return min(max(s, 0), 1)
    }

    // `applyControls` IS GONE. NOTHING MOVES THE ENDPOINTS ANY MORE.
    //
    // It ended up as the place every control had been bolted onto, and one by one
    // each turned out to belong somewhere else: density on the aim, contrast on
    // the slope about the aim, C/M/Y on a printer-light offset after both. The
    // endpoints are now purely what `measureEnds` found in the frame, which is
    // also what makes the histogram overlay honest.
    //
    // The order in `render16` is the whole design: stretch, expose, shape, balance.

    /// Which terminator to finish on, captured as a VALUE.
    ///
    /// The three `Paper` globals are `nonisolated(unsafe) var`s written from the
    /// menu bar on the main actor. Export renders in `Task.detached`, so reading
    /// them there raced: switching print model mid-export wrote some files with
    /// one terminator and some with another, and assigning a `PrintLUT` or an
    /// `ICCOnly.Transform` -- structs holding arrays -- while another thread
    /// reads the same var is an ARC race, not just a stale value.
    struct Terminator {
        let icc: ICCOnly.Transform?
        let lut: PrintLUT?
        let mono: Bool
        /// The stretched value this terminator renders as the print aim, solved
        /// ONCE when the value is snapshotted. `aimValue` is a 26-step bisection
        /// through the whole terminator, and `autoGamma` used to run it on every
        /// redraw to re-solve a number that only moves when the terminator does.
        let aim: Double
        /// DEV-CURVE, snapshotted for the same reason as the rest.
        let newCurve: Bool
        /// The built-in curve's span. Snapshotted because `aimValue` reads it and
        /// export renders detached -- the same ARC/staleness race the rest of this
        /// value exists to avoid.
        let span: Double

        /// Does this terminator HARD-CLAMP at white?
        ///
        /// This is why the shoulder is not applied unconditionally. An ICC or a
        /// .cube is a sampled table: it clips, and our shoulder is what saves it --
        /// blown highlights 2.35% -> 0.00% at Normal contrast. The built-in curve
        /// already approaches white through a softplus (`Paper.whiteSoftness`) and
        /// has its own shoulder (`Paper.shoulderN`), and measured it clips 0.00%
        /// at EVERY setting. Adding a second shoulder there only softens: old
        /// Hard 2 reads 229 on the built-in and the shouldered top read 226.
        ///
        /// So the shoulder goes where the clamp is.
        var clampsHard: Bool { icc != nil || lut != nil }

        init(icc: ICCOnly.Transform?, lut: PrintLUT?, mono: Bool,
             newCurve: Bool = false, span: Double = Paper.directSpan) {
            self.icc = icc; self.lut = lut; self.mono = mono
            self.newCurve = newCurve; self.span = span
            self.aim = Master.aimValue(icc: icc, lut: lut, span: span)
        }
        /// Read the globals. Call on the main actor, then hand the value over.
        static var current: Terminator {
            Terminator(icc: Paper.outputICC, lut: Paper.printLUT,
                       mono: Paper.monochrome, newCurve: Paper.newCurve,
                       span: Paper.directSpan)
        }
    }

    func render16(_ edit: Edit, _ term: Terminator = .current) -> [UInt16] {
        let n = width * height
        var rgb = [UInt16](repeating: 0, count: n * 3)
        // THE pipeline. One path, three interchangeable terminators.
        //
        //   master (Cineon, base-subtracted)
        //     -> levels stretch, per frame, masked to the frame rectangle
        //     -> ICC profile | .cube LUT | the built-in RA-4 curve
        //     -> sRGB
        //
        // The old log-domain paper path is gone: it pivoted on the frame's median
        // density, applied 100% exposure compensation, ran tone and gradation as
        // log-domain side slopes and finished on the paper curve. It was replaced
        // because the operator verified by hand that levels-then-profile is what
        // produces the look, and because running BOTH a paper simulation and a
        // print-emulation profile double-applies a tone curve -- the documented
        // failure mode of stacking a print rendering twice.
        //
        // The RA-4 curve needs a domain conversion the other two do not: it
        // consumes LOG EXPOSURE while the stretch hands over 0..1. That is
        // `directExposure`, and it is the only place the three differ.
        let (lo, hi) = directLevels(edit)
        // Stretch, clamp, exposure and contrast collapse into one table per
        // channel indexed by the master code -- the input is 16-bit, so the table
        // is exact, and it is cheaper than the arithmetic it replaces.
        //
        // ORDER MATTERS AND IS THE WHOLE FIX. Exposure first, placing the frame's
        // metered point on the aim; contrast second, as a slope PIVOTED ON THAT
        // AIM. Contrast therefore cannot move the exposure and exposure cannot
        // undo the contrast. They used to share the endpoints and fight.
        let ag = autoGamma(term, edit)
        let aim = Master.aimTarget(term, edit)
        let ks = Master.toneSlopes(edit, newCurve: term.newCurve)
        let cmy = Master.cmyOffsets(edit)
        let offs = [cmy.0, cmy.1, cmy.2]
        var curve = [[Float]](repeating: [], count: 3)
        for c in 0..<3 {
            curve[c] = (0..<65536).map { k in
                Float(Master.curveValue(Double(k) / 65535, lo: lo[c], hi: hi[c],
                                        gamma: ag, aim: aim, slopes: ks,
                                        offset: offs[c],
                                        shoulder: term.newCurve && term.clampsHard))
            }
        }
        let icc = term.icc
        let lut = term.lut
        let mono = term.mono               // DEV-MONO, hoisted out of the loop
        rgb.withUnsafeMutableBufferPointer { out in
        let dst = out.baseAddress!
        curve[0].withUnsafeBufferPointer { c0 in
        curve[1].withUnsafeBufferPointer { c1 in
        curve[2].withUnsafeBufferPointer { c2 in
            Master.bands(n) { b0, b1 in
                for i in b0..<b1 {
                    let r = c0[Int(planes[0][i])]
                    let gg = c1[Int(planes[1][i])]
                    let bb = c2[Int(planes[2][i])]
                    var o: (Float, Float, Float)
                    if let icc { o = icc.srgb((r, gg, bb)) }
                    else if let lut {
                        let v = lut.sample(r, gg, bb)
                        o = (PrintLUT.toSRGB(v.0), PrintLUT.toSRGB(v.1),
                             PrintLUT.toSRGB(v.2))
                    } else {
                        let sp = term.span
                        o = (Float(Paper.transfer(Master.directExposure(Double(r), span: sp), channel: 0)),
                             Float(Paper.transfer(Master.directExposure(Double(gg), span: sp), channel: 1)),
                             Float(Paper.transfer(Master.directExposure(Double(bb), span: sp), channel: 2)))
                    }
                    if mono {
                        // DEV-MONO: luma in linear light, then one value to all
                        // three. Whatever chroma the terminator invented on a
                        // neutral negative goes with it.
                        let y = Paper.lumaW.0 * Paper.srgbDecode(Double(o.0))
                              + Paper.lumaW.1 * Paper.srgbDecode(Double(o.1))
                              + Paper.lumaW.2 * Paper.srgbDecode(Double(o.2))
                        let v = Master.u16(Paper.srgbEncode(y))
                        dst[i * 3] = v; dst[i * 3 + 1] = v; dst[i * 3 + 2] = v
                        continue
                    }
                    dst[i * 3] = Master.u16(Double(o.0))
                    dst[i * 3 + 1] = Master.u16(Double(o.1))
                    dst[i * 3 + 2] = Master.u16(Double(o.2))
                }
            }
        }}}}
        return rgb
    }


    /// Split `n` elements into one contiguous band per core and run them
    /// concurrently. Below a threshold it just runs inline -- dispatch overhead
    /// costs more than the work on a thumbnail.
    @inline(__always)
    static func bands(_ n: Int, _ body: (Int, Int) -> Void) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard n > 64_000, cores > 1 else { body(0, n); return }
        let k = min(cores, 8)
        let per = (n + k - 1) / k
        DispatchQueue.concurrentPerform(iterations: k) { i in
            let lo = i * per, hi = min(n, lo + per)
            if lo < hi { body(lo, hi) }
        }
    }

    /// Rotate an interleaved buffer by whole quarter turns, clockwise.
    /// Index math rather than CoreGraphics: a 48-bit no-alpha CGContext cannot
    /// be created, so the CG route silently returns the image unrotated.
    static func rotate<T>(_ src: [T], w: Int, h: Int, comps: Int,
                          turns: Int) -> (buf: [T], w: Int, h: Int) {
        let q = ((turns % 4) + 4) % 4
        if q == 0 { return (src, w, h) }
        let (ow, oh) = q % 2 == 1 ? (h, w) : (w, h)
        var dst = src
        for y in 0..<h {
            for x in 0..<w {
                let (nx, ny): (Int, Int)
                switch q {
                case 1: (nx, ny) = (h - 1 - y, x)          // 90 cw
                case 2: (nx, ny) = (w - 1 - x, h - 1 - y)  // 180
                default: (nx, ny) = (y, w - 1 - x)         // 270 cw
                }
                let si = (y * w + x) * comps, di = (ny * ow + nx) * comps
                for c in 0..<comps { dst[di + c] = src[si + c] }
            }
        }
        return (dst, ow, oh)
    }

    // MARK: - Export

    func cgImage(_ edit: Edit, bits: Int, _ term: Terminator = .current) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let r = Master.rotate(render16(edit, term), w: width, h: height, comps: 3,
                              turns: edit.quarterTurns)
        let rgb16 = r.buf
        // Deliberately NOT self.width/height: a quarter turn swaps them, so the
        // post-rotation extent is what everything below must use. Named apart so
        // the shadowing is intentional rather than a trap.
        let outW = r.w, outH = r.h
        let n = outW * outH

        let bytes: Data
        let bpc: Int, bpp: Int, rowBytes: Int
        if bits == 16 {
            bpc = 16; bpp = 48; rowBytes = outW * 6
            bytes = rgb16.withUnsafeBufferPointer { Data(buffer: $0) }
        } else {
            bpc = 8; bpp = 24; rowBytes = outW * 3
            // >>8, not vImage's 16U->8U: that scales by 255/65535 and rounds,
            // which differs from a shift by up to one code. Kept exact -- this is
            // a few ms and not worth a silent change to every preview.
            var eight = [UInt8](repeating: 0, count: n * 3)
            rgb16.withUnsafeBufferPointer { src in
                eight.withUnsafeMutableBufferPointer { dst in
                    let sp = src.baseAddress!, dp = dst.baseAddress!
                    Master.bands(n * 3) { lo, hi in
                        for i in lo..<hi { dp[i] = UInt8(sp[i] >> 8) }
                    }
                }
            }
            bytes = eight.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let img = CGImage(width: outW, height: outH, bitsPerComponent: bpc,
                                bitsPerPixel: bpp, bytesPerRow: rowBytes, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                                    .union(bits == 16 ? .byteOrder16Little : []),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)
        else { throw Err("cannot build \(bits)-bit image") }
        return img
    }

    /// 16-bit TIFF keeps the full render; JPEG is the delivery file.
    func write(_ edit: Edit, to url: URL, as type: UTType, quality: Double = 0.92,
               _ term: Terminator = .current) throws {
        let bits = (type == .tiff || type == .png) ? 16 : 8
        let img = try cgImage(edit, bits: bits, term)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                        type.identifier as CFString, 1, nil)
        else { throw Err("cannot create \(url.lastPathComponent)") }
        // TIFF carries a 3144-byte sRGB profile; JPEG carries none, and that is
        // ImageIO's decision, not ours. Tried and measured as having no effect:
        // the named sRGB space, a space rebuilt from its own ICC bytes,
        // img.copy(colorSpace:), and kCGImageDestinationOptimizeColorForSharing
        // = false. ImageIO will not write an sRGB profile into a JPEG.
        //
        // Left alone deliberately. An untagged JPEG is read as sRGB by every
        // browser and viewer, so nothing is actually at risk. Revisit only if
        // this ever exports a WIDER space -- Display P3 or Adobe RGB untagged
        // would genuinely be wrong, and then the fix is to write the APP2
        // segment directly rather than to keep negotiating with ImageIO.
        CGImageDestinationAddImage(dest, img,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw Err("cannot write \(url.lastPathComponent)")
        }
    }
}

struct Err: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

/// Everything the operator can change about one frame. Deliberately just
/// integers plus a preset -- the same state the reference machine serialises to
/// back-print, and small enough to keep in a sidecar.
struct Edit: Codable, Equatable {
    var cyan = 0, magenta = 0, yellow = 0   // key presses, +-20
    var density = 0                          // key presses, +-50
    var high: Paper.Grade = .standard      // Tone Adjustment, highlight side
    var shadow: Paper.Grade = .standard    // Tone Adjustment, shadow side
    /// Gradation Selection: the BASE contrast, -3...+2 = Soft3...Hard2.
    ///
    /// A separate control from Tone Adjustment on the real machine, on a
    /// different tab, described as "changing the main gradation based on gray".
    /// Tone Adjustment trims a region; this sets the whole curve. It is also
    /// where the machine's extra-hard lives -- Tone Adjustment has no such step.
    var gradation: Int = 0
    var quarterTurns = 0        // F2 Rotate, 0-3 clockwise


    var isNeutral: Bool { cyan == 0 && magenta == 0 && yellow == 0 && density == 0
        && high == .standard && shadow == .standard && gradation == 0
        && quarterTurns == 0 }

    /// Tolerant decoding, in BOTH directions: a missing key and an out-of-range
    /// value both fall back to the default rather than throwing. The synthesised
    /// decoder fails on a missing key, so adding a field would orphan every
    /// existing edits.json; and one bad enum value would take the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cyan = try c.decodeIfPresent(Int.self, forKey: .cyan) ?? 0
        magenta = try c.decodeIfPresent(Int.self, forKey: .magenta) ?? 0
        yellow = try c.decodeIfPresent(Int.self, forKey: .yellow) ?? 0
        density = try c.decodeIfPresent(Int.self, forKey: .density) ?? 0
        // Via Int, not the enum. `decodeIfPresent(Grade.self)` THROWS on a
        // rawValue outside -2...2, and edits.json decodes as ONE dictionary, so a
        // single bad value made the whole roll's corrections unreadable -- and
        // then every frame looked neutral, which deletes the file.
        // `try?`, so a WRONG TYPE is as survivable as a wrong value.
        high = ((try? c.decodeIfPresent(Int.self, forKey: .high)) ?? nil)
            .flatMap(Paper.Grade.init(rawValue:)) ?? .standard
        shadow = ((try? c.decodeIfPresent(Int.self, forKey: .shadow)) ?? nil)
            .flatMap(Paper.Grade.init(rawValue:)) ?? .standard
        gradation = try c.decodeIfPresent(Int.self, forKey: .gradation) ?? 0
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
    }
    init() {}
    /// The reference machine shows an unset key as "No"; 0 reads better here.
    static func keyLabel(_ v: Int) -> String { v == 0 ? "0" : (v > 0 ? "+\(v)" : "\(v)") }

    mutating func apply(_ b: Paper.ToneButton) {
        high = b.effect.high
        shadow = b.effect.shadow
    }
    /// Compact per-frame readout for the film strip: only what is set.
    var stripSummary: String {
        var parts: [String] = []
        if cyan != 0 { parts.append("C\(cyan)") }
        if magenta != 0 { parts.append("M\(magenta)") }
        if yellow != 0 { parts.append("Y\(yellow)") }
        if density != 0 { parts.append("D\(density)") }
        if high != .standard { parts.append("H:\(high.short)") }
        if shadow != .standard { parts.append("S:\(shadow.short)") }
        if gradation != 0 { parts.append("G\(gradation > 0 ? "+" : "")\(gradation)") }
        // isNeutral counts rotation, so this must too, or a frame that is only
        // rotated reads "not neutral" with nothing to show -- an empty chip.
        if quarterTurns != 0 { parts.append("R\(quarterTurns * 90)") }
        return parts.joined(separator: " ")
    }
    var toneSummary: String {
        if high == .standard && shadow == .standard { return "Standard" }
        return "H:\(high.short) S:\(shadow.short)"
    }
}


extension Int {
    func clamped(_ r: Int) -> Int { Swift.min(Swift.max(self, -r), r) }
}
