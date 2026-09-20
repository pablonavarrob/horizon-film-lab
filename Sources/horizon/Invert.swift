import Accelerate
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Negative -> Cineon master.
///
/// It began as a port of `n2c_v5.py`, kept as a line-by-line mirror so a diff
/// against it stayed meaningful. That is no longer true and the claim is
/// withdrawn rather than left to mislead: `--invert-diff` does not exist, the
/// border detection is a different algorithm entirely (DEV-EDGE), and DEV-FLOOR
/// deliberately writes the 95 Cineon codes below reference black that the Python
/// clamps away. The sampling strides and percentile conventions are still
/// inherited from it, which is why they look arbitrary.
enum Invert {

    // MARK: - Capture grouping

    /// How the captures are laid out. Four cases, all of which occur:
    ///  - three mono files, one per LED (the narrowband rig)
    ///  - three colour files, take channel i from each
    ///  - one colour file (a single colour capture)
    ///  - one mono file (a black-and-white negative)
    enum Layout: String { case mono3, rgb3, rgb1, mono1 }

    /// Set by `group` when it had to take alphanumeric triples rather than read
    /// a channel suffix. Read by the caller purely to SAY SO -- the frame count
    /// it produces is the cheapest check that the chosen mode is right.
    nonisolated(unsafe) static var groupedByOrder = false

    /// Why grouping produced nothing, when it did. Reported instead of the bare
    /// "no captures" that a refused roll would otherwise get.
    nonisolated(unsafe) static var groupIssue: String?

    static let channelSuffix = try! NSRegularExpression(
        pattern: "[._-]([rgb]|[123])[rgb]?$", options: .caseInsensitive)

    /// Group a folder of captures into frames, R,G,B in that order. Accepts
    /// _r/_g/_b, _1/_2/_3 and the combined _1R/_2G/_3B; otherwise takes
    /// consecutive triples in alphanumeric order.
    ///
    /// The alphanumeric path is NOT a last resort -- most rigs write no channel
    /// suffix at all and simply shoot R, G, B in order. What changed is that it
    /// is only reached when the operator has SELECTED a 3-shot mode. It used to
    /// be reachable by inference, from nothing but "the file count divides by
    /// three", which silently turned six white-light single shots into two
    /// frames built from three different photographs.
    static func group(_ urls: [URL], layout: Layout) -> [[URL]] {
        groupedByOrder = false
        groupIssue = nil
        let files = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return [] }   // e.g. a roll with no LCC captures
        if layout == .rgb1 || layout == .mono1 { return files.map { [$0] } }

        var keyed: [String: [Int: URL]] = [:]
        var ok = true
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            let r = NSRange(stem.startIndex..., in: stem)
            guard let m = channelSuffix.firstMatch(in: stem, range: r),
                  let g = Range(m.range(at: 1), in: stem) else { ok = false; break }
            let token = stem[g].lowercased()
            let idx = ["r": 0, "g": 1, "b": 2, "1": 0, "2": 1, "3": 2][token]!
            let key = String(stem[stem.startIndex..<Range(m.range, in: stem)!.lowerBound])
            keyed[key, default: [:]][idx] = f
        }
        if ok, !keyed.isEmpty {
            let complete = keyed.filter { Set($0.value.keys) == Set([0, 1, 2]) }
            if complete.count == keyed.count {
                return keyed.keys.sorted().map { k in [keyed[k]![0]!, keyed[k]![1]!, keyed[k]![2]!] }
            }
            // Every file carries a channel suffix but some frame is missing one.
            // Falling through to blind triples here would build frames from
            // channels of DIFFERENT exposures, so refuse and say which.
            let bad = keyed.filter { Set($0.value.keys) != Set([0, 1, 2]) }.keys.sorted()
            groupIssue = "incomplete channel set for \(bad.count) frame(s): "
                + bad.prefix(3).joined(separator: ", ")
                + (bad.count > 3 ? "…" : "")
            return []
        }
        guard files.count % 3 == 0 else { return [] }
        var out: [[URL]] = []
        for i in Swift.stride(from: 0, to: files.count, by: 3) { out.append(Array(files[i..<i + 3])) }
        guard out.first != nil else { return [] }
        groupedByOrder = true
        return out
    }

    // MARK: - Capture loading

    /// Raw 16-bit planes straight off disk. No colour management: these are
    /// sensor counts, and a CGContext would transfer-function them.
    static func planes(_ url: URL) throws -> (p: [[Float]], w: Int, h: Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else {
            throw Err("cannot read \(url.lastPathComponent)")
        }
        let w = img.width, h = img.height
        let comps = img.bitsPerPixel / max(img.bitsPerComponent, 1)
        let rowBytes = img.bytesPerRow
        let big = img.byteOrderInfo == .order16Big
        let bits = img.bitsPerComponent
        guard bits == 16 || bits == 8 else {
            throw Err("\(url.lastPathComponent) is \(bits)-bit; expected 8 or 16")
        }
        // 8-bit is accepted but it is a poor container for density work: 256
        // levels across the whole scale, and a negative only occupies a
        // fraction of them, so the shadows quantise visibly.
        if bits == 8 {
            FileHandle.standardError.write(
                "! \(url.lastPathComponent) is 8-bit — density precision will be coarse\n"
                    .data(using: .utf8)!)
        }
        // 1 or 3 planes, never 2. A grey+alpha or RGBA TIFF reports 2 or 4
        // components; taking `min(comps, 3)` gave 2 planes for the former, and
        // every consumer indexes [0], [1] and [2] unconditionally -- an
        // out-of-bounds trap on load rather than an error the operator can read.
        guard comps >= 1 else { throw Err("\(url.lastPathComponent) has no channels") }
        var out = [[Float]](repeating: [Float](repeating: 0, count: w * h),
                            count: comps >= 3 ? 3 : 1)
        let nc = out.count
        let comps8 = img.bitsPerPixel / 8
        data.withUnsafeBytes { buf in
            if bits == 8 {
                for c in 0..<nc {
                    out[c].withUnsafeMutableBufferPointer { dst in
                        let base = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        for y in 0..<h {
                            let row = base + y * rowBytes
                            vDSP_vfltu8(row + c, comps8, dst.baseAddress! + y * w, 1,
                                        vDSP_Length(w))
                        }
                        var inv = Float(1.0 / 255.0)
                        vDSP_vsmul(dst.baseAddress!, 1, &inv, dst.baseAddress!, 1,
                                   vDSP_Length(w * h))
                    }
                }
                return
            }
            // vDSP_vfltu16 does the strided UInt16 -> Float conversion a whole
            // row at a time. Element-by-element, this was the single biggest
            // cost in the inversion: 3 files x 3 components x 31 Mpx of scalar
            // Float(_:) with bounds checks, ~0.28 s a frame on its own.
            for c in 0..<nc {
                out[c].withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = buf.baseAddress!.advanced(by: y * rowBytes)
                            .assumingMemoryBound(to: UInt16.self)
                        let d = dst.baseAddress! + y * w
                        if big {
                            // Swap into place first, then convert; still two
                            // vector passes rather than w scalar ones.
                            for x in 0..<w { d[x] = Float(row[x * comps + c].byteSwapped) }
                        } else {
                            vDSP_vfltu16(row + c, comps, d, 1, vDSP_Length(w))
                        }
                    }
                    var inv = Float(1.0 / 65535.0)
                    vDSP_vsmul(dst.baseAddress!, 1, &inv, dst.baseAddress!, 1,
                               vDSP_Length(w * h))
                }
            }
        }
        return (out, w, h)
    }

    /// One frame as three density-ready count planes, following the layout.
    static func frame(_ urls: [URL], layout: Layout) throws -> (p: [[Float]], w: Int, h: Int) {
        if urls.count == 1 {
            let (p, w, h) = try planes(urls[0])
            if layout == .mono1 || p.count == 1 {
                // B&W: one density channel, replicated. The paper curve and the
                // printer lights then work unchanged and the print is neutral by
                // construction; Density and the gradation columns do the work.
                return ([p[0], p[0], p[0]], w, h)
            }
            return (p, w, h)
        }
        guard urls.count == 3 else { throw Err("expected 1 or 3 captures, got \(urls.count)") }
        var out: [[Float]] = []
        var W = 0, H = 0
        for (i, u) in urls.enumerated() {
            let (p, w, h) = try planes(u)
            if i == 0 { W = w; H = h } else if w != W || h != H {
                throw Err("captures differ in size")
            }
            if p.count == 1 { out.append(p[0]) }
            else if layout == .rgb3 { out.append(p[i]) }
            else {
                // mono sensor written as RGB: average the identical channels
                var m = [Float](repeating: 0, count: w * h)
                let n = vDSP_Length(w * h)
                var third = Float(1.0 / 3.0)
                m.withUnsafeMutableBufferPointer { d in
                    p[0].withUnsafeBufferPointer { a in
                        p[1].withUnsafeBufferPointer { b in
                            vDSP_vadd(a.baseAddress!, 1, b.baseAddress!, 1,
                                      d.baseAddress!, 1, n)
                        }
                    }
                    p[2].withUnsafeBufferPointer { c in
                        vDSP_vadd(d.baseAddress!, 1, c.baseAddress!, 1,
                                  d.baseAddress!, 1, n)
                    }
                    vDSP_vsmul(d.baseAddress!, 1, &third, d.baseAddress!, 1, n)
                }
                out.append(m)
            }
        }
        return (out, W, H)
    }

    /// 2x2 box mean, matching the oracle's `half=True` probe. The probe has to
    /// see the same pixels as Python or the roll base and slopes drift.
    static func halve(_ p: [[Float]], _ w: Int, _ h: Int) -> (p: [[Float]], w: Int, h: Int) {
        let ow = w / 2, oh = h / 2
        var out = [[Float]](repeating: [Float](repeating: 0, count: ow * oh), count: p.count)
        for c in 0..<p.count {
            for y in 0..<oh {
                for x in 0..<ow {
                    let a = p[c][(y * 2) * w + x * 2], b = p[c][(y * 2) * w + x * 2 + 1]
                    let d = p[c][(y * 2 + 1) * w + x * 2], e = p[c][(y * 2 + 1) * w + x * 2 + 1]
                    out[c][y * ow + x] = (a + b + d + e) / 4
                }
            }
        }
        return (out, ow, oh)
    }

    // MARK: - LCC (flat field)

    /// Lens-cast / flat-field reference. A capture of the bare light path with
    /// no film in the gate, shot at the start of a session.
    ///
    /// Deliberately NOT blurred. My Python reference smooths the flat (sigma 8)
    /// so its sensor noise is not injected into every frame — but that also
    /// erases the very thing you want corrected here: a scratch on the sensor
    /// glass is high spatial frequency, and blurring the flat blurs the fix
    /// away. Average several flats instead if the noise bothers you; that keeps
    /// the defect and divides the noise by sqrt(N).
    static func loadLCC(_ groups: [[URL]], layout: Layout) throws
        -> (p: [[Float]], w: Int, h: Int)? {
        guard !groups.isEmpty else { return nil }
        var acc: [[Float]] = []
        var fw = 0, fh = 0
        for g in groups {
            let (p, w, h) = try frame(g, layout: layout)
            if fw == 0 { fw = w; fh = h }
            guard w == fw, h == fh else {
                throw Err("LCC flats differ in size: \(fw)x\(fh) vs \(w)x\(h)")
            }
            if acc.isEmpty { acc = p } else {
                for c in 0..<3 {
                    var one = Float(1)
                    acc[c].withUnsafeMutableBufferPointer { a in
                        p[c].withUnsafeBufferPointer { b in
                            vDSP_vsma(b.baseAddress!, 1, &one, a.baseAddress!, 1,
                                      a.baseAddress!, 1, vDSP_Length(a.count))
                        }
                    }
                }
            }
        }
        if groups.count > 1 {
            var n = Float(groups.count)
            for c in 0..<3 {
                acc[c].withUnsafeMutableBufferPointer { a in
                    vDSP_vsdiv(a.baseAddress!, 1, &n, a.baseAddress!, 1, vDSP_Length(a.count))
                }
            }
        }
        return (acc, fw, fh)
    }

    /// Bilinear rescale, used to fit a flat to the captures.
    ///
    /// A flat is a smooth optical field, so resampling it is legitimate — which is
    /// why only the ASPECT has to match. A different aspect means a different
    /// optical path or a different crop, and then the flat describes something
    /// else. Note this does soften dust: at reduced resolution a speck lands
    /// between pixels, so dust correction is only exact at capture resolution.
    static func rescale(_ p: [[Float]], fromW: Int, fromH: Int,
                        toW: Int, toH: Int) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: toW * toH),
                            count: p.count)
        let sx = Double(fromW) / Double(toW), sy = Double(fromH) / Double(toH)
        for c in 0..<p.count {
            p[c].withUnsafeBufferPointer { src in
                out[c].withUnsafeMutableBufferPointer { dst in
                    for y in 0..<toH {
                        let fy = min(Double(fromH) - 1, max(0, (Double(y) + 0.5) * sy - 0.5))
                        let y0 = Int(fy), y1 = min(y0 + 1, fromH - 1)
                        let ty = Float(fy - Double(y0))
                        for x in 0..<toW {
                            let fx = min(Double(fromW) - 1, max(0, (Double(x) + 0.5) * sx - 0.5))
                            let x0 = Int(fx), x1 = min(x0 + 1, fromW - 1)
                            let tx = Float(fx - Double(x0))
                            let a = src[y0 * fromW + x0], b = src[y0 * fromW + x1]
                            let e = src[y1 * fromW + x0], f = src[y1 * fromW + x1]
                            let top = a + (b - a) * tx, bot = e + (f - e) * tx
                            dst[y * toW + x] = top + (bot - top) * ty
                        }
                    }
                }
            }
        }
        return out
    }

    /// Pixel dimensions from the header, without decoding the image.
    static func imageSize(_ url: URL) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let d = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = d[kCGImagePropertyPixelWidth] as? Int,
              let h = d[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Files whose name marks them as a flat/LCC rather than a frame.
    static func isLCC(_ url: URL) -> Bool {
        let n = url.deletingPathExtension().lastPathComponent.lowercased()
        return n.hasPrefix("lcc") || n.hasPrefix("flat") || n.hasPrefix("blank")
            || n.contains("_lcc") || n.contains("_flat")
    }

    // MARK: - Border



    /// The frame rectangle inside the gate, in pixels.
    struct Border: Codable, Equatable {
        var left = 0, top = 0, right = 0, bottom = 0   // insets
        var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }

        /// The inside of the border as half-open bounds, or the whole image if
        /// what is left would be too small to measure. Callers reading pixel
        /// statistics all want this: the rebate renders near-black and the gate
        /// near-white, and either one in the numbers dominates them.
        func inner(w: Int, h: Int, least: Int = 32) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
            guard !isEmpty else { return (0, w, 0, h) }
            let x0 = max(0, left), x1 = min(w, w - right)
            let y0 = max(0, top), y1 = min(h, h - bottom)
            guard x1 - x0 >= least, y1 - y0 >= least else { return (0, w, 0, h) }
            return (x0, x1, y0, y1)
        }

        /// DEV-GATE — the rectangle inside the picture on EVERY frame of the
        /// roll: the worst inset found on each side. One gate for the whole
        /// roll, which is what a real film gate is.
        ///
        /// WHY THIS EXISTS. `rebateRun` returns 0 for "found nothing on this
        /// side", which is indistinguishable from "no inset here" -- so a frame
        /// whose detection partly failed measures its statistics THROUGH THE
        /// REBATE. The rebate is dense, so it drags the p99.98 white endpoint
        /// and squeezes the whole picture down. Measured: DSCF1574 reads p99.98
        /// at D 1.677 through its own border and 0.888 through this gate, a 2.6
        /// STOP error; 10 of 37 frames on one roll have at least one side at 0
        /// and they are precisely the frames that printed dark (-2.96, -3.04,
        /// -3.05, -4.08, -4.20 EV against aim).
        ///
        /// Costs 8% of the mean per-frame picture area and masks STATISTICS
        /// ONLY -- the pixels are never cropped by this -- so an over-wide gate
        /// is never destructive, which is why the worst side wins rather than
        /// the mean. Roll-level GEOMETRY, not roll-level tone: no frame's
        /// pixel values reach any other frame's rendering.
        static func gate(of borders: [String: Border]) -> Border {
            borders.values.reduce(into: Border()) {
                $0.left = max($0.left, $1.left)
                $0.top = max($0.top, $1.top)
                $0.right = max($0.right, $1.right)
                $0.bottom = max($0.bottom, $1.bottom)
            }
        }

    }

    /// Border detected at full res, applied to half-res data.
    static func halveBorder(_ b: Border) -> Border {
        Border(left: b.left / 2, top: b.top / 2, right: b.right / 2, bottom: b.bottom / 2)
    }

    // ============================== DEV-EDGE ==============================
    // Per-frame film edge detection, by density projection. Replaces
    // detectBorder + the roll median + reseat, all three of which it makes
    // unnecessary. TO REMOVE: grep DEV-EDGE. It is load-bearing in more places
    // than a single call now -- `detectEdges`, `lineStats`, `rebateRun`, the
    // per-frame rectangles in `Session`, and the mask every consumer of
    // `Border.inner` reads -- so treat the grep as the list.
    //
    // The border is not one thing: the film rebate is CLEAR while the carrier is
    // OPAQUE, so the test cannot be "bright" or "dark". No ABSOLUTE gate can
    // bracket the rebate either -- it sits at D 0.10-0.15 while the deepest
    // scene shadows sit at 0.00, so the rebate lives in the MIDDLE of the range.
    // The old `sceneFloor = 0.20` read 0.00 in the rebate and 0.00-0.08 in dark
    // interior columns, indistinguishable, which is how `place` (a brightness
    // centroid, not an edge finder) walked 1400 px into the picture and the roll
    // lost a mean 17.6% of frame width.
    //
    // WHAT IS INVARIANT: the rebate is UNIFORM. Per-column IQR reads 0.015-0.021
    // in the rebate on every frame of this roll against 0.02-0.47 in the
    // picture. IQR and not p97-p3, because the rebate carries "KODAK 200" edge
    // printing that a wide spread reads as texture -- it biased a first attempt
    // 174 px short.
    //
    // Flatness alone is not enough -- a blown sky is as flat as rebate, and on
    // the sunset frame that cost 1138 px -- so the test is flat AND at the
    // frame's own base density. See DEV-DMIN in `rebateRun` for that half.
    /// Flatness floors, one per axis, because they are different borders: the
    /// rebate between frames reads IQR 0.020 down a column and the film edge
    /// against the carrier 0.030 across a row, while even a dark flat picture is
    /// 0.039 or more. A single value serves one axis and silently returns 0 for
    /// the other -- which is what happened while this was one constant: left and
    /// right landed within 26 px while top and bottom detected nothing at all.
    /// The row value is looser because that rebate carries the edge printing.
    static let edgeFlatCol: Float = 0.030
    static let edgeFlatRow: Float = 0.045
    /// Nothing may crop more than this per side, ever. The truth on a real roll
    /// is at most 6.1% of the width; the old detector once took 22%. A frame is
    /// a rectangle near the middle of the capture, so a runaway edge is always
    /// wrong and this bounds the damage to something survivable no matter how
    /// badly the search is fooled.
    static let edgeCap = 0.12
    /// Where the carrier reads. A clip, so it survives base subtraction.
    static let gateCeiling = (maxCodeD * 0.985)
    static let edgeRun = 24

    /// Below this density a sample is SATURATED, not thin.
    ///
    /// Density is measured against the clear gate, so film density is strictly
    /// positive -- a sample reading zero sits at or beyond the reference white,
    /// which nothing with film in front of it can do. So it is a clipped sensor
    /// value, and a clipped value is DESTROYED data, not flat data.
    ///
    /// That distinction is the whole guard. An IQR of zero from saturated pixels
    /// is indistinguishable from an IQR of zero from perfectly uniform rebate, so
    /// the detector read the clipped band as border. Measured on DSCF1501, whose
    /// outer 66 columns are 65% clipped:
    ///
    ///   cols 0..60   R 0.128  G 0.000  B 0.000   <- saturated, IQR 0.006
    ///   cols 80..120 R 0.53   G 0.69   B 0.21    <- the real rebate, and it
    ///                                               matches the roll's own base
    ///                                               estimate 0.54/0.71/0.24
    ///
    /// The margin is the entire distance from 0.000 to 0.207, so this is not a
    /// tuned threshold -- it is "greater than zero" with numerical slack.
    static let satFloor: Float = 0.02

    /// Cineon ceiling in density, for spotting the opaque carrier.
    static let maxCodeD = (Paper.maxCode - Paper.codeOffset) / Paper.codeSlope

    /// Per-line spread and median of mean density, down one axis.
    ///
    /// The window spans the FULL perpendicular extent, minus whatever is passed
    /// in `skip`. A middle-70% window was the single worst bug in this detector:
    /// it made one frame's deep-shadow left edge read as 1994 px of false rebate,
    /// and two frames' fogged left edge read as carrier. Measured over the full
    /// extent the classes separate cleanly -- rebate 0.020 down a column, 0.030
    /// across a row, and even a dark flat picture is 0.039 or more.
    ///
    /// `skip` exists because the rows must not be profiled through the left and
    /// right borders: those are uniform, so they drag a row's spread down toward
    /// the rebate's and blur the top and bottom edges. So the columns are
    /// measured first and the rows are measured inside them.
    private static func lineStats(_ D: [[Float]], w: Int, h: Int, vertical: Bool,
                                  skip: (Int, Int) = (0, 0))
        -> (spread: [Float], med3: [[Float]]) {
        let n = vertical ? w : h                 // lines to profile
        let m = vertical ? h : w                 // extent along each line
        let lo = skip.0, hi = m - skip.1
        guard hi - lo > 32 else {
            return ([Float](repeating: 0, count: n),
                    [[Float]](repeating: [Float](repeating: 0, count: n), count: 3))
        }
        let stride = max(1, (hi - lo) / 420)      // ~420 samples is plenty
        var spread = [Float](repeating: 0, count: n)
        // DEV-DMIN: per-channel medians. The per-channel MAX beats the mean of
        // three by 41% on worst-case margin -- a deep shadow keeps its exposure
        // in one dye layer and a mean averages that away.
        var med3 = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        var ch = [[Float]](repeating: [], count: 3)
        var buf = [Float](); buf.reserveCapacity((hi - lo) / stride + 1)
        for i in 0..<n {
            buf.removeAll(keepingCapacity: true)
            for c in 0..<3 { ch[c].removeAll(keepingCapacity: true) }
            var total = 0, j = lo
            while j < hi {
                let idx = vertical ? j * w + i : i * w + j
                let r = D[0][idx], g = D[1][idx], b = D[2][idx]
                total += 1
                // Saturated samples are dropped rather than averaged in: one
                // clipped channel drags the mean toward zero and takes the IQR
                // with it, which is how a blown border band came to look flatter
                // than film.
                if min(r, min(g, b)) > satFloor {
                    buf.append((r + g + b) / 3)
                    ch[0].append(r); ch[1].append(g); ch[2].append(b)
                }
                j += stride
            }
            // A line that is mostly destroyed cannot be classified. It must fail
            // LOUDLY: leaving spread at its initial 0 makes it read as perfectly
            // flat, i.e. as border, which is the opposite of what not-knowing
            // should mean. This hole predates the saturation test -- the old
            // `buf.count > 8` bail-out did exactly that.
            guard buf.count > 8, buf.count * 2 > total else {
                spread[i] = .greatestFiniteMagnitude
                continue
            }
            buf.sort()
            let q = buf.count / 4
            spread[i] = buf[buf.count - 1 - q] - buf[q]
            for c in 0..<3 {
                ch[c].sort()
                med3[c][i] = ch[c][ch[c].count / 2]
            }
        }
        return (spread, med3)
    }

    /// How many lines of border at the start of a profile.
    ///
    /// THREE region types, measured on all 22 edges of a real roll:
    ///   carrier/gate  median pinned at the Cineon ceiling
    ///   film rebate   spread 0.020 down a column, 0.030 across a row
    ///   picture       0.039 upwards, even when dark and flat
    ///
    /// Two structures broke every earlier version:
    ///
    ///  - SEQUENTIAL BANDS. Four edges run gate -> rebate -> picture. Stopping at
    ///    the first line that is not rebate stops inside the gate, which cost
    ///    69-122 px on those edges.
    ///  - A SLIVER OF THE NEIGHBOURING FRAME outside the rebate. Two edges carry
    ///    38 and 113 px of the ADJACENT exposure before the interframe rebate
    ///    starts, so the border does not touch the capture edge at all and a
    ///    naive walk returns 0 for a 415 px border.
    ///
    /// So: walk outside-in, treat gate and rebate alike, and forgive one short
    /// run of picture at the very outside. The ceiling test is only safe in this
    /// direction -- in raw negative density a blown highlight also reaches the
    /// ceiling, so an unordered scan would read bright scene as carrier.
    ///
    private static func rebateRun(_ spread: [Float], _ med3: [[Float]],
                                  flat flatFloor: Float, base: [Float]?, tol: Float,
                                  sliver allowSliver: Bool, reversed: Bool) -> Int {
        let n = spread.count
        let cap = min(n - 1, Int(Double(n) * edgeCap))
        guard cap > edgeRun else { return 0 }
        // DEV-DMIN: a noise floor derived from this axis's own quietest lines,
        // not a self-calibrating gap test. This can be loosened to 1.8x the 1st
        // percentile ONLY because the density test below now rejects flat
        // picture -- on its own it costs roll B its heights. Swept: k = 1.6/1.8/
        // 2.2 gives roll A 9.8/9.2/9.6 and roll B 43.7/43.1/60.0.
        var usable = [Float]()
        usable.reserveCapacity(cap)
        for i in 0..<cap {
            let v = spread[reversed ? n - 1 - i : i]
            if v.isFinite { usable.append(v) }
        }
        var flat = flatFloor
        if usable.count > 16 {
            usable.sort()
            flat = max(flatFloor, usable[max(0, usable.count / 100)] * 1.8)
        }
        let sliver = Int(Double(n) * 0.025)     // 160 px on a 6464 px axis
        var streak = 0, edge = 0
        for i in 0..<cap {
            let k = reversed ? n - 1 - i : i
            let q = spread[k]
            // DEV-DMIN. Three ways to be border, and the density test is what
            // lets the other two be strict:
            //  - opaque, by MIN over channels. The carrier is opaque in every
            //    channel; a blown negative is opaque in one or two. Measured,
            //    gateCeiling 1.828 sits in the gap: real carrier reads 1.92-6.00
            //    min-channel, blown negative 1.33 and 1.53. The old mean-of-three
            //    test called those two blown frames carrier and ate 232 columns.
            //  - at base, by MAX over channels against a per-channel Dmin.
            //  - flat, which alone is worth nothing on 20 of 109 edges.
            let opaque = min(med3[0][k], min(med3[1][k], med3[2][k])) >= Float(gateCeiling)
            var atBase = true
            if let bs = base {
                var worst: Float = 0
                for c in 0..<3 { worst = max(worst, med3[c][k] - bs[c]) }
                atBase = worst < tol
            }
            let isBorder = opaque || (q < flat && atBase)
            if isBorder { streak = 0; edge = i + 1; continue }
            streak += 1
            guard streak >= edgeRun else { continue }
            let start = i - streak + 1
            // THREE ATTEMPTS TO TIGHTEN THIS HAVE FAILED, because the two rigs
            // want opposite things at this exact decision point.
            //
            // Symptom: six frames on the 135 roll report a top inset of 60..114
            // against a truth of 19..24, because this forgives a 49..60 row band
            // of picture and a dark flat band beyond it then becomes the edge.
            //
            //   (a) forgiven run must END in the sliver, not START there -- fixes
            //       1450 T114->41, breaks 1504 R148->104 and roll B's 540
            //       T136->52. Net loss on both rolls.
            //   (b) forgive only while nothing is accepted yet (edge == 0) --
            //       fixes four of the six tops EXACTLY (18/19/19/23), breaks two
            //       right edges and costs roll B 0.0155 -> 0.0202 aspect error.
            //   (c) forgive only while everything accepted is opaque carrier --
            //       worse than (b) on both rolls: loses the fixes, keeps the harm.
            //
            // Why they disagree, which is the useful part: the 135 roll's top rows
            // read D ~3.0, ABOVE gateCeiling, so that top is carrier abutting
            // picture -- no rebate at all, and nothing past the carrier boundary
            // may be forgiven. The 6x7 roll's top runs carrier -> gap -> rebate ->
            // picture and its correct 107..136 inset REQUIRES forgiving the gap.
            // Same signal, opposite requirement.
            //
            // So no rule local to the sliver can fix it: separating them needs to
            // know whether the band AFTER the forgiven run is real rebate or dark
            // scene at rebate density -- the same unsolved problem as DSCF1450's
            // bottom.
            if allowSliver && start <= sliver && streak <= sliver { streak = 0; continue }
            return edge
        }
        // REACHING THE CAP IS A FAILURE, NOT AN ANSWER.
        //
        // Falling out of the loop means border-like lines ran the whole search
        // window without a solid run of picture ever closing them off, so the
        // walk never found an edge -- it ran out of room. Returning `edge` here
        // handed back a number indistinguishable from a real detection, and it
        // was always about the cap: B391 = 0.12 x 3264, R586 and L587 = 0.12 x
        // 4896. Eight frames of 33 on one roll, each quietly masking 12% of a
        // side. Leaving the rebate in costs a visible strip; cropping 300 px of
        // picture and biasing the frame's own exposure statistics with it costs
        // the photograph, so 0 is the safe direction to fail in.
        return 0
    }

    // ============================== DEV-DMIN ==============================
    // An absolute per-channel film-base test, ALONGSIDE the flatness test.
    //
    // The rebate IS Dmin -- clear base plus fog -- so it has an absolute density,
    // where the flatness test only asks whether a line is uniform. Measured over
    // 109 edges of two rolls, that distinction is the whole game:
    //
    //                                 roll A        roll B
    //   density gap rebate->picture   +0.608 med    +0.334 med
    //     worst case, per-channel max +0.190        +0.130
    //   IQR ratio picture/rebate      6.46 med      3.00 med
    //     worst case                  0.77          0.51
    //   edges with IQR ratio <= 1.5   15 / 79       5 / 30
    //
    // On 20 of 109 edges the flatness criterion has NO separation, and on 7 the
    // picture is FLATTER than the rebate. Density separates all 106 real rebate
    // edges. And the two fail on DISJOINT edges -- one frame's right rebate reads
    // IQR 0.036 against picture at 0.033, no signal at all, but a density gap of
    // +0.92 D. That disjointness is why this is a second criterion and never a
    // replacement.
    //
    // EVERY PART OF THIS IS A REGRESSION ON ITS OWN. Measured by ablation, mean
    // |width error| in px, roll A / roll B: the density test alone 119.5 / 68.7
    // against 42.9 / 91.5 for the current detector; the loosened noise floor
    // alone 37.0 / 81.9 but wrecks the heights; deleting the row sliver alone
    // 42.9 / 91.5 with heights at 22.1 / 201.0. Together: 9.2 / 43.1. They
    // interlock -- the floor can only be loosened BECAUSE density rejects flat
    // picture, and the row sliver can only go BECAUSE density classifies the
    // bare-gate band directly. That is why three previous attempts at the sliver
    // alone all lost.
    //
    // TO REMOVE: grep DEV-DMIN. Four sites: `provisionalBase`, the per-channel
    // medians in `lineStats`, the classifier in `rebateRun`, and the plumbing in
    // `detectEdges`.
    // =======================================================================

    /// Per-channel film base, estimated WITHOUT knowing the border.
    ///
    /// The outer ring only, low-tail mode. Measured against the base later taken
    /// from the found rebate it agrees to 0.001-0.005 D on 8 of 11 frames, 0.032
    /// on two, 0.131 on one pathological frame -- which is why the tolerance
    /// against it is loose (0.15) and the one against the measured base is tight
    /// (0.06). Two tolerances, two reference qualities, not one knob.
    ///
    /// A mode, not a percentile: it beats p5/p10 by about 1.5x on the second rig.
    /// But it is NOT a clean isolated peak -- FWHM 0.09-0.90 D, and only 5-27% of
    /// the ring's mass sits within +-0.02 D of it. It is a robust location
    /// estimator on a broad shoulder; do not describe it as peak detection.
    ///
    /// Blurring first was tested and changes every estimator by <= 0.006 D.
    /// Per-line medians and histogram modes are already outlier-robust.
    static func provisionalBase(_ D: [[Float]], w: Int, h: Int) -> [Float]? {
        let bx = max(1, Int(Double(w) * 0.12)), by = max(1, Int(Double(h) * 0.12))
        let bins = 3000, top: Float = 6.0
        var hist = [[Int]](repeating: [Int](repeating: 0, count: bins), count: 3)
        var count = 0
        var y = 0
        while y < h {
            let inTopBot = y < by || y >= h - by
            var x = 0
            while x < w {
                if inTopBot || x < bx || x >= w - bx {
                    let i = y * w + x
                    let r = D[0][i], g = D[1][i], b = D[2][i]
                    if min(r, min(g, b)) > satFloor {
                        for c in 0..<3 {
                            let v = min(max(D[c][i], 0), top)
                            hist[c][min(bins - 1, Int(v / top * Float(bins)))] += 1
                        }
                        count += 1
                    }
                }
                x += 4
            }
            y += 4
        }
        guard count > 500 else { return nil }
        var out = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            // The lowest quarter of the mass: the base is the thin end, and the
            // picture above it would otherwise dominate the mode.
            var acc = 0, cut = bins - 1
            for b in 0..<bins { acc += hist[c][b]; if acc >= count / 4 { cut = b; break } }
            var best = 0, bestAt = 0
            for b in 0...cut {
                var sum = 0
                for k in max(0, b - 12)...min(bins - 1, b + 12) { sum += hist[c][k] }
                if sum > best { best = sum; bestAt = b }
            }
            out[c] = (Float(bestAt) + 0.5) / Float(bins) * top
        }
        return out
    }

    /// DEV-EDGE — the frame rectangle, from this frame alone.
    static func detectEdges(_ D: [[Float]], w: Int, h: Int) -> Border {
        let capW = Int(Double(w) * edgeCap), capH = Int(Double(h) * edgeCap)
        // DEV-DMIN: a per-channel base guessed from the outer ring, before any
        // border is known. nil means the frame gave no unsaturated ring mass, in
        // which case the density test abstains and flatness decides alone.
        let prov = provisionalBase(D, w: w, h: h)
        // Columns first, over the full height.
        let col = lineStats(D, w: w, h: h, vertical: true)
        let left = min(rebateRun(col.spread, col.med3, flat: edgeFlatCol,
                                 base: prov, tol: 0.15,
                                 sliver: true, reversed: false), capW)
        let right = min(rebateRun(col.spread, col.med3, flat: edgeFlatCol,
                                  base: prov, tol: 0.15,
                                  sliver: true, reversed: true), capW)
        // DEV-DMIN: now MEASURE the base, per channel, from the rebate the column
        // pass actually found. That is a far better reference than the ring guess
        // -- mean error 0.019 D against 0.032 typical / 0.131 worst -- so the row
        // pass can use a tolerance three times tighter. Lines at the ceiling are
        // excluded: several edges run gate THEN rebate, and sampling the gate
        // hands back 1.856, which matches nothing.
        var measured: [Float]? = nil
        var pool = [[Float]](repeating: [], count: 3)
        for c in 0..<3 {
            if left > 32 {
                pool[c] += (0..<left).map { col.med3[c][$0] }
                    .filter { $0 < Float(gateCeiling) }
            }
            if right > 32 {
                pool[c] += ((w - right)..<w).map { col.med3[c][$0] }
                    .filter { $0 < Float(gateCeiling) }
            }
        }
        if pool[0].count > 16 {
            measured = (0..<3).map { c -> Float in
                pool[c].sort(); return pool[c][pool[c].count / 2]
            }
        }
        // Then rows, measured INSIDE those columns so the uniform side borders
        // cannot drag a row's spread down toward the rebate's. The column pass has
        // to resolve first, which is why this call sits here and not above.
        //
        // NO SLIVER FORGIVENESS ON THE ROWS. It existed for a band of bare gate
        // outside the rebate, which the density test now classifies directly --
        // traced on one frame, rows 0-136 read 0.105-0.123 D THINNER than film
        // base, i.e. no film in the path, then row 137 jumps +0.090 with IQR
        // 0.45. The forgiveness was eating 50-75 rows of real picture on six
        // frames of the other roll. It stays for columns, where deleting it costs
        // roll A 9.2 -> 43.7.
        let row = lineStats(D, w: w, h: h, vertical: false, skip: (left, right))
        let b = Border(left: left,
                       top: min(rebateRun(row.spread, row.med3,
                                          flat: edgeFlatRow, base: measured ?? prov,
                                          tol: measured == nil ? 0.15 : 0.06,
                                          sliver: false, reversed: false), capH),
                       right: right,
                       bottom: min(rebateRun(row.spread, row.med3,
                                             flat: edgeFlatRow, base: measured ?? prov,
                                             tol: measured == nil ? 0.15 : 0.06,
                                             sliver: false, reversed: true), capH))

        // THE ASPECT-RATIO REPAIR IS GONE, and cannot be made safe: the prior it
        // trusts is wrong by about as much as the errors it corrects. On frames
        // whose four edges are all verified transitions the measured aspect is
        // 1.468 +- 0.005 on the 135 roll (nominal 1.500) and 1.2597 +- 0.001 on
        // the 6x7 (nominal 1.250) -- OPPOSITE directions, so not one correctable
        // offset, and its 2% trigger fired on CORRECT detections.
        //
        // Per frame it fired on 11 of 33, and every firing pulled 97..141 px
        // inward on a side, taking insets of 122..153 down to 7..42 where the
        // correct value is 105..155: verified rebate (IQR 0.025..0.041) dragged
        // inside the mask, which also shifts the base estimate unevenly per
        // channel (DSCF1462 R and G by 0.013 D against B's 0.001). Against
        // nominal it read as a win (0.0225 -> 0.0109); against the MEASURED
        // aspect it was the worst regression in the table (0.0191 -> 0.0287). It
        // was scored on its own prior. Ledger: 11 harmful firings against 1
        // beneficial.
        //
        // The over-detection left behind is the cheaper direction: the border is
        // a statistics MASK, not a crop, so excluded picture costs sampling area
        // while included rebate biases the numbers.
        //
        // The film-format picker went with it: with nothing to constrain, the
        // control was inert, so it was a menu that did nothing.
        //
        // Do not reinstate without per-frame evidence that the aspect prior beats
        // the errors being corrected. Snapping to the nearest standard format was
        // tried and is reliable only when all four edges are already closed, i.e.
        // exactly the frames needing no repair: two of eleven 6x7 frames snapped
        // to half-frame, one on a 0.003 margin, and half-frame 1.333 against 645's
        // 1.349 are 0.016 apart -- finer than the 0.8-2.1% offsets above.
        return b
    }

    // ======================================================================

    // MARK: - Density

    /// counts -> absolute density. `response` is the flat already dark-subtracted.
    /// Vectorised: vDSP for the arithmetic, vForce for the log. The scalar
    /// version spent 0.50s per frame on 94M calls to log10f; this is the same
    /// maths with the same result, on 4-wide SIMD.
    /// In-place. The encode loop holds a 377 MB buffer per frame; handing back a
    /// fresh array meant the input stayed alive alongside it for no reason, and
    /// two of those in the chain put peak use at ~1.4 GB a frame -- which is what
    /// made running frames in parallel swap instead of scale.
    static func densityInPlace(_ out: inout [[Float]], dark: [[Float]]?,
                               response: [[Float]]?) {
        for c in 0..<3 {
            let n = out[c].count
            var cnt = Int32(n)
            out[c].withUnsafeMutableBufferPointer { x in
                if let dark {
                    dark[c].withUnsafeBufferPointer { d in
                        vDSP_vsub(d.baseAddress!, 1, x.baseAddress!, 1,
                                  x.baseAddress!, 1, vDSP_Length(n))
                    }
                }
                if let response {
                    response[c].withUnsafeBufferPointer { r in
                        vDSP_vdiv(r.baseAddress!, 1, x.baseAddress!, 1,
                                  x.baseAddress!, 1, vDSP_Length(n))
                    }
                }
                var lo: Float = 1e-6, hi = Float.greatestFiniteMagnitude
                vDSP_vclip(x.baseAddress!, 1, &lo, &hi, x.baseAddress!, 1, vDSP_Length(n))
                vvlog10f(x.baseAddress!, x.baseAddress!, &cnt)
                var m: Float = -1
                vDSP_vsmul(x.baseAddress!, 1, &m, x.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }

    /// Copying wrapper, for the probe paths that still need their input after.
    static func density(_ counts: [[Float]], dark: [[Float]]?,
                        response: [[Float]]?) -> [[Float]] {
        var out = counts
        densityInPlace(&out, dark: dark, response: response)
        return out
    }

    // MARK: - numpy-compatible statistics
    //
    // These have to match numpy exactly or the diff against the oracle is
    // meaningless: linear-interpolated percentiles, and a median that averages
    // the two middle values on an even count.

    static func percentile(_ sorted: [Float], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q / 100.0 * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        let t = pos - Double(lo)
        return Double(sorted[lo]) * (1 - t) + Double(sorted[hi]) * t
    }

    static func median(_ v: [Float]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? Double(s[n / 2])
                          : (Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2
    }

    /// Subsample exactly as `px[::max(1, n // 400_000)]` does.
    static func step(_ n: Int, _ target: Int = 400_000) -> Int {
        max(1, n / target)
    }

    // MARK: - Calibration

    /// Film base density: the minimum-density region. With a flat applied the
    /// bare light path reads D~0 while clear film base reads above it, so
    /// `floor` separates "no film" from "unexposed film".
    /// With a border known, the film base is the REBATE — outside the frame but
    /// not the opaque carrier. That is a far better base estimate than "lowest
    /// density anywhere", which picks bare light path or a blown highlight and
    /// is why some frames inverted badly.
    static func estimateBase(_ D: [[Float]], w: Int, h: Int, border: Border,
                             clipAt: Double) -> [Double]? {
        guard !border.isEmpty else { return nil }
        var rows: [[Float]] = [[], [], []]
        var neutral: [Float] = []
        let ceil = Float(clipAt * 0.98)
        for y in 0..<h {
            let outsideRow = y < border.top || y >= h - border.bottom
            for x in 0..<w where outsideRow || x < border.left || x >= w - border.right {
                let i = y * w + x
                let r = D[0][i], g = D[1][i], b = D[2][i]
                // SATURATED PIXELS ARE THE THINNEST THING OUT HERE, and this
                // function selects on thinness -- the 20th percentile below --
                // so without a floor they win outright and become the base.
                //
                // That is what wrecked DSCF1501 and DSCF1537. Their G and B
                // captures clip over a band at the film edge, and the base came
                // back R 0.125 / G 0.000 / B 0.000 -- exactly the saturated
                // band's own reading -- against a true rebate of 0.53/0.69/0.21.
                // So G and B had nothing subtracted while R lost 0.125, and the
                // master carried a 0.23 D channel imbalance where a good frame
                // on this roll carries 0.03. The whole cyan-green cast was this.
                //
                // The `ceil` test above already refuses the opaque carrier at the
                // dense end; this is the missing half of that guard, and it is
                // the same rule `lineStats` uses. Film density is measured
                // against the clear gate, so it is strictly positive -- a zero is
                // a destroyed sample, not a thin one.
                guard min(r, min(g, b)) > satFloor else { continue }
                let d = (r + g + b) / 3
                guard d < ceil else { continue }          // opaque carrier
                neutral.append(d)
                for c in 0..<3 { rows[c].append(D[c][i]) }
            }
        }
        guard neutral.count > 2000 else { return nil }
        // DEV-BARELIGHT: the MODE of the thin end, not its 20th percentile.
        //
        // A percentile assumes the thinnest samples out here are film base. They
        // are not when part of the capture has NO FILM IN IT -- bare light past
        // the film edge is thinner than base and, having no orange mask, nearly
        // neutral. Measured on scan_20260823_185253_527: an 88 px strip down the
        // right edge is 10.0% of the outside-border region, so the thinnest 20%
        // is a bare-light/rebate mixture and its median lands in the wrong
        // population -- base came back [0.148 0.136 0.113] against a true rebate
        // of [0.484 0.804 1.197]. Under-subtracting a B-heavy base leaves ~1.08 D
        // of excess blue, and the frame rendered at R/G/B 0.51/1.00/2.01: the
        // "one frame goes blue" report.
        //
        // A mode is robust to a 10% contaminant, needs no threshold tuned to this
        // rig's exposure, and works for a B&W negative too (where base IS neutral,
        // so a chromaticity test would not). Same technique as `provisionalBase`.
        // Measured: fixes the broken frame to [0.480 0.797 1.173] and moves good
        // frames by at most 0.006 D, a fifth of one printer-light key.
        //
        // TO REMOVE: grep DEV-BARELIGHT. Restoring the percentile is two lines.
        let sortedNeutral = neutral.sorted()
        let bins = 3000, top = 6.0
        let lowCut = Float(percentile(sortedNeutral, 25.0))
        var hist = [Int](repeating: 0, count: bins)
        for v in neutral where v <= lowCut {
            let k = Int((Double(v) / top) * Double(bins))
            if k >= 0 && k < bins { hist[k] += 1 }
        }
        // Box-smooth so a spiky histogram cannot pick a single noise bin.
        let win = 25
        var best = 0, bestSum = -1, running = 0
        for k in 0..<bins {
            running += hist[k]
            if k >= win { running -= hist[k - win] }
            if running > bestSum { bestSum = running; best = max(0, k - win / 2) }
        }
        let centre = Float((Double(best) + 0.5) / Double(bins) * top)
        var sel: [Int] = []
        for i in 0..<neutral.count where abs(neutral[i] - centre) < 0.05 { sel.append(i) }
        if sel.count < 500 {
            // No coherent thin population: fall back to the old percentile rather
            // than trust a mode built from a handful of samples.
            let thresh = Float(percentile(sortedNeutral, 20.0))
            sel = []
            for i in 0..<neutral.count where neutral[i] <= thresh { sel.append(i) }
        }
        return (0..<3).map { c in median(sel.map { rows[c][$0] }) }
    }

    static func estimateBase(_ D: [[Float]], floor: Double) -> [Double] {
        let n = D[0].count, st = step(n)
        var dmean: [Float] = [], rows: [[Float]] = [[], [], []]
        var i = 0
        while i < n {
            let r = D[0][i], g = D[1][i], b = D[2][i]
            // Same saturation guard as the border-based overload, and needed here
            // for a reason that overload's `floor` does not cover: `floor` is 0.0
            // whenever there is no flat-field capture, and the filter below tests
            // the MEAN of three channels. A pixel whose G and B are clipped to
            // zero still means (0.128 + 0 + 0) / 3 = 0.043, which clears a floor
            // of zero comfortably -- so two destroyed channels sail through on the
            // strength of the one surviving them.
            //
            // This overload is the no-border fallback AND the source of the
            // PROVISIONAL base that the border detector is then measured against,
            // so a wrong answer here propagates into the geometry as well as the
            // colour.
            if min(r, min(g, b)) <= satFloor { i += st; continue }
            dmean.append((r + g + b) / 3)
            for c in 0..<3 { rows[c].append(D[c][i]) }
            i += st
        }
        guard dmean.count > 64 else { return [0, 0, 0] }
        var keep = dmean.indices.filter { Double(dmean[$0]) > floor }
        if keep.count < 1000 { keep = Array(dmean.indices) }
        let kept = keep.map { dmean[$0] }
        let thresh = percentile(kept.sorted(), 0.5)
        let sel = keep.filter { Double(dmean[$0]) <= thresh }
        return (0..<3).map { c in median(sel.map { rows[c][$0] }) }
    }

    // MARK: - Border diagnostics

    /// A small JPEG showing what the border detector actually decided, so its
    /// quality can be judged rather than assumed.
    ///
    ///   MAGENTA any channel saturated — DESTROYED data, not a reading
    ///   grey    inside the frame, real scene density
    ///   ORANGE  inside the frame but AT BASE LEVEL — should probably be outside
    ///   BLUE    at the density ceiling — opaque carrier, or sensor floor
    ///   RED     outside the frame, sampled as film base (the rebate)
    ///   green rectangle — the detected frame edge
    ///
    /// The orange is the whole point. A first version rendered base-level and
    /// deep-shadow pixels the same near-black, so I misread dark scene as
    /// missed rebate and "found" a detection bug that did not exist. If orange
    /// appears inside the green box, the detector under-cut; if the red band
    /// misses your rebate, the base is being read off the wrong thing.
    static func writeBorderDebug(_ D: [[Float]], w: Int, h: Int, base: [Double],
                                 border: Border, clipAt: Double, to url: URL,
                                 maxEdge: Int = 900) {
        let st = max(1, max(w, h) / maxEdge)
        let ow = w / st, oh = h / st
        guard ow > 8, oh > 8 else { return }
        var rgb = [UInt8](repeating: 0, count: ow * oh * 3)
        let bm = Float((base[0] + base[1] + base[2]) / 3)
        let ceil = Float(clipAt * 0.98)
        // Scale the positive by the frame's own range so it is always legible.
        let span: Float = 1.2

        for oy in 0..<oh {
            let sy = oy * st
            let outsideRow = sy < border.top || sy >= h - border.bottom
            for ox in 0..<ow {
                let sx = ox * st
                let i = sy * w + sx
                let d = (D[0][i] + D[1][i] + D[2][i]) / 3
                let dn = max(d - bm, 0)
                // Rough positive: more negative density = brighter scene.
                var v = Int(min(max(dn / span, 0), 1) * 235) + 10
                let outside = outsideRow || sx < border.left || sx >= w - border.right
                let atBase = dn < 0.06          // indistinguishable from film base
                let atCeil = d >= ceil          // carrier, or sensor floor
                // MAGENTA, and it wins over every other class: a channel at or
                // below the saturation floor is destroyed, and destroyed data must
                // not be drawn as though it were a reading. Rendered as ordinary
                // rebate, a clipped band at the film edge looked exactly like a
                // good base sample -- which is what it was being used as.
                let blown = min(D[0][i], min(D[1][i], D[2][i])) <= satFloor
                var r = v, g = v, b = v
                if blown {
                    r = 255; g = 0; b = 220
                } else if outside {
                    if atCeil { r = 30; g = 30; b = 200 }
                    else { r = min(255, v / 2 + 140); g = v / 4; b = v / 4 }
                } else if atCeil {
                    r = 60; g = 60; b = 230
                } else if atBase {
                    r = 245; g = 150; b = 20     // orange: base level, inside the frame
                }
                // Frame edge in green.
                let edge = abs(sx - border.left) < st * 2
                    || abs(sx - (w - 1 - border.right)) < st * 2
                    || abs(sy - border.top) < st * 2
                    || abs(sy - (h - 1 - border.bottom)) < st * 2
                if edge && !outside { r = 40; g = 255; b = 40 }
                let o = (oy * ow + ox) * 3
                rgb[o] = UInt8(r); rgb[o + 1] = UInt8(g); rgb[o + 2] = UInt8(b)
                v = 0
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytes = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: bytes as CFData),
              let img = CGImage(width: ow, height: oh, bitsPerComponent: 8,
                                bitsPerPixel: 24, bytesPerRow: ow * 3, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                            UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
    }

    // MARK: - Encode

    /// Negative density -> image density. THE WHOLE INVERSION.
    ///
    /// Subtract the film base, per channel, per frame. That is all.
    ///
    /// There used to be a per-channel slope fitted here. It is gone, and its
    /// absence is the point. Colour negative layers are designed with closely
    /// matched gammas -- a few percent -- so a fit that swings +-35% between
    /// frames of one roll is not measuring film, it is absorbing SCENE COLOUR.
    /// Measured R-channel slopes on eleven frames: 0.771 to 1.204. That is what
    /// stripped the character out of the strongly coloured frames.
    ///
    /// Narrowband RGB through a mono sensor is what makes this enough: each
    /// exposure reads essentially one dye layer, with none of the filter
    /// crosstalk a minilab's CCD has to correct for. Clean dye densities minus
    /// the mask IS the inversion. Nothing to fit, nothing scene-dependent, no
    /// branch.
    /// DEV-FLOOR — the master may carry density BELOW the estimated base, down
    /// into the 95 Cineon codes that sit under reference black.
    ///
    /// This used to clamp at 0, and `cineon` clamps again at code 95, so those 95
    /// codes were never written and everything at or under the base collapsed
    /// onto one value. Measured inside the frame, rebate excluded, worst channel:
    /// 16.1% of real scene on 17_540, 18.8% on 05_952, 15.5% on 33_558. Letting
    /// it through recovered 143 distinct codes of red shadow on 05_952 and took
    /// that channel from 1.49% pinned to 0.04%.
    ///
    /// It is grading material: a log master exists to carry what a display
    /// encoding cannot, and crushing the shadows in the FILE throws away the one
    /// thing the format is for. Set black when you grade, not here.
    ///
    /// Blue is barely helped -- 14.7% to 13.2% -- because on a warm sunset the
    /// negative genuinely has no blue exposure there. That is the film, not us.
    ///
    /// TO REMOVE: grep DEV-FLOOR. Two sites, and both are required: the clamp in
    /// `imageDensityInPlace` and the code clip in `cineon`. Lifting one and not
    /// the other is what made this a no-op the first time.
    static func imageDensityInPlace(_ out: inout [[Float]], base: [Double]) {
        for c in 0..<3 {
            let n = out[c].count
            var negB = Float(-base[c])
            var lo = Float(-Paper.codeOffset / Paper.codeSlope)   // DEV-FLOOR
            var hi = Float.greatestFiniteMagnitude
            out[c].withUnsafeMutableBufferPointer { x in
                vDSP_vsadd(x.baseAddress!, 1, &negB, x.baseAddress!, 1, vDSP_Length(n))
                vDSP_vclip(x.baseAddress!, 1, &lo, &hi, x.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }



    static func cineon(_ Dn: [[Float]], slope: Double = Paper.codeSlope) -> [UInt16] {
        let n = Dn[0].count
        var rgb = [UInt16](repeating: 0, count: n * 3)
        var sl = Float(slope), off = Float(Paper.codeOffset)
        // DEV-FLOOR: 0, not `codeOffset`. This is the SECOND of the two floors,
        // and only the first ever got lowered -- so `imageDensityInPlace` let
        // density down to -0.19 and this line clipped the code straight back up
        // to 95, making DEV-FLOOR a no-op in the shipped master. Measured before
        // the fix: min code 95.0 on all 11 frames, up to 21.6% of a frame pinned
        // at exactly 95 -- a fifth of the picture on one flat value, which is
        // what "fade in the blacks" is. A floor lifted in one place and still
        // enforced in another is the recurring shape of this bug.
        var lo: Float = 0, hi = Float(Paper.maxCode)
        var k = Float(65535.0 / Paper.maxCode), half: Float = 0.5
        var tmp = [Float](repeating: 0, count: n)
        for c in 0..<3 {
            tmp.withUnsafeMutableBufferPointer { t in
                Dn[c].withUnsafeBufferPointer { src in
                    vDSP_vsmsa(src.baseAddress!, 1, &sl, &off, t.baseAddress!, 1, vDSP_Length(n))
                }
                vDSP_vclip(t.baseAddress!, 1, &lo, &hi, t.baseAddress!, 1, vDSP_Length(n))
                vDSP_vsmsa(t.baseAddress!, 1, &k, &half, t.baseAddress!, 1, vDSP_Length(n))
                // vfixu16 truncates, so the +0.5 above makes this round-half-up,
                // which is what numpy's (x+0.5).astype(uint16) does in the oracle.
                rgb.withUnsafeMutableBufferPointer { dst in
                    vDSP_vfixu16(t.baseAddress!, 1, dst.baseAddress! + c, 3, vDSP_Length(n))
                }
            }
        }
        return rgb
    }

    static func writeMaster(_ rgb: [UInt16], w: Int, h: Int, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!   // tag only; data is density
        let bytes = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 16,
                                bitsPerPixel: 48, bytesPerRow: w * 6, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                                    .union(.byteOrder16Little),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                            UTType.tiff.identifier as CFString, 1, nil)
        else { throw Err("cannot write \(url.lastPathComponent)") }
        // Uncompressed, deliberately. Cineon log is high-entropy so deflate
        // only bought 157 MB vs 188 MB -- 17% of disk for 5.7s of CPU per frame,
        // which was 83% of the whole inversion. The master is a rebuildable
        // cache; disk is cheaper than your time.
        CGImageDestinationAddImage(dest, img, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw Err("cannot finalise \(url.lastPathComponent)")
        }
    }
}

// MARK: - Driver

extension Invert {
    /// A STARTING POINT for the import picker, not a decision.
    ///
    /// This was `detectLayout` and it was authoritative, which is what made a
    /// wrong guess destructive: nothing in the file names distinguishes three
    /// narrowband exposures of one frame from three consecutive single shots, so
    /// no amount of inference here can be trusted. The operator picks; this only
    /// seeds the popup, and only where the evidence is actually conclusive:
    ///
    ///  - count not divisible by 3   -> single shot, certain (cannot be triples)
    ///  - single-channel files       -> the mono variant, and B&W by default:
    ///                                  one panchromatic plane carries no colour
    ///  - otherwise                  -> 3-shot, the stated default, because most
    ///                                  rigs shoot R,G,B in name order
    ///
    /// A channel suffix is NOT consulted here. It would be conclusive evidence of
    /// a 3-shot set, but the default is already 3-shot at every count where the
    /// question arises, so testing for it changed no answer.
    static func suggestLayout(_ urls: [URL]) -> (layout: Layout, monochrome: Bool)? {
        guard let mono = monoCaptures(urls) else { return nil }
        // A count that does not divide by three CANNOT be triples.
        let r = layoutAndFilm(threeShot: urls.count % 3 == 0, mono: mono)
        return (r.layout, r.monochrome)
    }

    /// Is each capture a single channel? A FACT about the files, so the import
    /// picker does not ask it -- it reads it. This is why there are four layouts
    /// but only one question.
    static func monoCaptures(_ urls: [URL]) -> Bool? {
        guard let first = urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              let src = CGImageSourceCreateWithURL(first as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img.bitsPerPixel / max(img.bitsPerComponent, 1) < 3
    }

    /// The four layouts are two independent facts: shots per frame, and whether
    /// the files are mono. Only the first needs asking.
    ///
    /// `mono1` carries its film type with it. One panchromatic plane has no
    /// colour information in it at all, so black and white is not a choice there
    /// -- which is why the picker states it rather than offering it.
    /// `settled` means the film type is not a choice: derived, not offered.
    static func layoutAndFilm(threeShot: Bool, mono: Bool)
        -> (layout: Layout, monochrome: Bool, settled: Bool) {
        if threeShot { return (mono ? .mono3 : .rgb3, false, false) }
        return mono ? (.mono1, true, true) : (.rgb1, false, false)
    }


    /// What the roll was inverted with. Written beside the masters so a re-run
    /// reproduces the same result instead of re-guessing.
    struct Session: Codable {
        var layout: String = "rgb3"
        var lcc: [String] = []
        /// Per-frame frame rectangle, keyed by master stem. The film's position
        /// shifts between captures, so one rectangle per roll is not enough --
        /// and this is a MASK for statistics, never a crop.
        var frameBorders: [String: Border] = [:]
        var perFrameBase = true
        var useBorder = true
        /// DEV-MONO. A render property, recorded here because it belongs to the
        /// roll and must survive a re-invert.
        var monochrome = false

        init(layout: String = "rgb3", lcc: [String] = [],
             frameBorders: [String: Border] = [:], perFrameBase: Bool = true,
             useBorder: Bool = true, monochrome: Bool = false) {
            self.layout = layout; self.lcc = lcc
            self.frameBorders = frameBorders; self.perFrameBase = perFrameBase
            self.useBorder = useBorder; self.monochrome = monochrome
        }

        /// EVERY field is optional on the way in, because Swift's SYNTHESIZED
        /// decoder ignores property defaults and throws on a missing key.
        ///
        /// That is not a detail. Adding `monochrome` to this struct made every
        /// previously inverted roll fail to decode its session.json, which silently
        /// dropped all 33 frame rectangles and moved every frame's levels -- the
        /// mask is what keeps the rebate out of the endpoint percentiles. It looked
        /// like a colour regression in the renderer.
        ///
        /// Written this way once so the struct is permanently additive-safe: a new
        /// field can never again break an old roll. Removing a field was always
        /// safe -- unknown keys in the JSON are ignored.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "rgb3"
            lcc = try c.decodeIfPresent([String].self, forKey: .lcc) ?? []
            frameBorders = try c.decodeIfPresent([String: Border].self,
                                                 forKey: .frameBorders) ?? [:]
            perFrameBase = try c.decodeIfPresent(Bool.self, forKey: .perFrameBase) ?? true
            useBorder = try c.decodeIfPresent(Bool.self, forKey: .useBorder) ?? true
            monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
        }
    }

    /// session.json sits one level above the cache the masters go into. One
    /// definition, because the writer and both readers disagreeing would be
    /// invisible until a roll silently lost its rectangles.
    static func sessionURL(beside out: URL) -> URL {
        out.deletingLastPathComponent().appendingPathComponent("session.json")
    }

    static func loadSession(beside out: URL) -> Session? {
        guard let d = try? Data(contentsOf: sessionURL(beside: out)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }

    static func run(dir: URL, layout: Layout, perFrameBase: Bool, out: URL,
                    only: Set<String>? = nil, useBorder: Bool = true,
                    lcc: [URL]? = nil, debugBorder: Bool = false,
                    monochrome: Bool = false,
                    progress: ((String) -> Void)? = nil) throws {
        let exts: Set<String> = ["tif", "tiff", "png"]
        let all = (try FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil))
            .filter { exts.contains($0.pathExtension.lowercased()) }
        // An LCC chosen in Settings wins; otherwise fall back to captures in
        // this folder whose name marks them as a flat.
        let lccFiles = (lcc?.isEmpty == false) ? lcc! : all.filter(isLCC)
        let frames = group(all.filter { !isLCC($0) }, layout: layout)
        let byOrder = groupedByOrder     // before the LCC grouping resets it
        guard !frames.isEmpty else {
            throw Err(groupIssue ?? "no captures in \(dir.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Say how they were grouped, not just how many. On a wrong capture mode
        // the frame count is a third of the capture count, which is instantly
        // visible; a stderr warning was not.
        // Say how they were grouped, on BOTH surfaces. On a wrong capture mode the
        // frame count is a third of the capture count, which is instantly visible;
        // the stderr warning this replaces was not visible in the GUI at all.
        let how = byOrder
            ? "\(all.count) captures -> \(frames.count) frame(s), \(layout.rawValue), alphanumeric R,G,B"
            : "\(frames.count) frame(s), \(layout.rawValue)"
        progress?(how)
        print("\(how) -> \(out.path)")

        let clipAt = (Paper.maxCode - Paper.codeOffset) / Paper.codeSlope

        // --- LCC ------------------------------------------------------------
        // GROUPED PER FILE IF THE FRAME LAYOUT DOES NOT FIT.
        //
        // Flats used to be grouped with the FRAME layout, so any count that was
        // not a multiple of three was silently discarded -- no warning, no error,
        // no effect. One flat per session is the normal way to shoot them, so on
        // a 3-shot roll the common case was "LCC does nothing", which is
        // indistinguishable from LCC being broken. Verified: 3 suffixed flats
        // removed a 50% vignette exactly (corner/centre 1.000) while 1 flat did
        // nothing at all.
        //
        // `frame()` already handles a one-file group: a single-channel flat is
        // replicated across the three channels, a 3-channel one is taken as-is.
        var lccGroups = group(lccFiles, layout: layout)
        if lccGroups.isEmpty, !lccFiles.isEmpty { lccGroups = lccFiles.map { [$0] } }
        var response: [[Float]]? = nil
        var lccSkipped = false
        if let lcc = try loadLCC(lccGroups, layout: layout) {
            // FIT THE FLAT TO THE CAPTURES. A flat is a smooth optical field, so a
            // size difference is not a reason to refuse -- only a different ASPECT
            // is, because that means a different optical path or crop.
            let cap = frames.first.flatMap { imageSize($0[0]) }
            if let cap, lcc.w != cap.w || lcc.h != cap.h {
                let aFlat = Double(lcc.w) / Double(lcc.h)
                let aCap = Double(cap.w) / Double(cap.h)
                if abs(aFlat - aCap) <= 0.01 * aCap {
                    response = rescale(lcc.p, fromW: lcc.w, fromH: lcc.h,
                                       toW: cap.w, toH: cap.h)
                    print("LCC rescaled \(lcc.w)x\(lcc.h) -> \(cap.w)x\(cap.h)")
                } else {
                    // SKIP, DO NOT FAIL. A flat with the wrong aspect belongs to a
                    // different camera/light setup, and `lccPaths` is app-wide, so
                    // this happens simply by opening one roll after another. Killing
                    // the whole inversion for it wrote ZERO masters -- far worse than
                    // inverting without a flat and saying so.
                    let msg = "LCC SKIPPED: flat is \(lcc.w)x\(lcc.h) (aspect "
                        + String(format: "%.3f", aFlat) + "), captures are "
                        + "\(cap.w)x\(cap.h) (aspect " + String(format: "%.3f", aCap)
                        + ") - it belongs to a different setup"
                    print("! " + msg)
                    progress?(msg)
                    response = nil
                    lccSkipped = true
                }
            } else {
                response = lcc.p
            }
        }
        if response != nil {
            let n = lccFiles.count
            let how = n > 1 ? "\(n) averaged" : "1"
            progress?("LCC: \(how) flat capture(s)")
            print("LCC applied from \(how) capture(s): \(lccFiles.map(\.lastPathComponent))")
        } else if !lccFiles.isEmpty, !lccSkipped {
            print("! LCC IGNORED: \(lccFiles.count) flat(s) could not be read")   // never silent again
            progress?("LCC ignored: flats unreadable")
        }
        // With a flat applied, bare light reads D~0 and clear film base reads
        // meaningfully above it, so a floor can separate them. Without one it
        // cannot, which is why base estimation was fragile.
        let floor = response != nil ? 0.08 : 0.0

        // --- probe -----------------------------------------------------------
        let n = min(frames.count, 6)
        let idx = (0..<n).map { n == 1 ? 0 : Int((Double($0) * Double(frames.count - 1)
                                                 / Double(n - 1)).rounded()) }
        var bases: [[Double]] = []
        for i in idx {
            let (p0, w0, h0) = try frame(frames[i], layout: layout)
            // Last-resort check: the flat divides the frame pixel for pixel, so a
            // surviving mismatch would be an out-of-bounds read. The rescale above
            // should make this unreachable.
            if let r = response, r[0].count != w0 * h0 {
                throw Err("LCC flat is \(r[0].count) px, captures are \(w0 * h0) px "
                        + "(\(w0)x\(h0)) -- rescale did not fit")
            }
            let (p, hw, hh) = halve(p0, w0, h0)     // oracle probes at half res
            let hr = response.map { halve($0, w0, h0).p }
            let D = density(p, dark: nil, response: hr)
            // Provisional base first, then the border relative to it, then the
            // proper rebate-based base inside that border.
            let prov = estimateBase(D, floor: floor)
            var b = Border()
            if useBorder {
                // Full resolution: at half res the 2x2 box average blurs the
                // rebate/scene transition. Base estimation stays on the halved
                // data, because that is what the Python oracle does.
                let Dfull = density(p0, dark: nil, response: response)
                b = detectEdges(Dfull, w: w0, h: h0)                    // DEV-EDGE
                print(String(format: "  probe %@ -> x %d..%d (w %d)  y %d..%d (h %d)",
                             frames[i][0].deletingPathExtension().lastPathComponent,
                             b.left, w0 - b.right, w0 - b.left - b.right,
                             b.top, h0 - b.bottom, h0 - b.top - b.bottom))
            }
            bases.append(estimateBase(D, w: hw, h: hh, border: halveBorder(b), clipAt: clipAt)
                         ?? prov)
        }
        // The probe exists ONLY to pool the film base, for when --per-frame-base
        // is off. There is no roll border any more: it was the last roll-level
        // statistic in the pipeline, and on a real roll its per-edge medians came
        // from different frames and produced a width (5043 px) that matched no
        // frame at all -- against a truth of 5856..6348.
        // SEEDED from the session this run will overwrite, not empty.
        //
        // This map is the ONLY record of the frame rectangles, and session.json is
        // rewritten wholesale below. Starting empty meant a single-frame re-invert
        // (Cmd-R, or --only) deleted the other 32 of 33 -- and a frame with no
        // rectangle has no statistics mask, so its levels are then measured over
        // the rebate and its colour changes. Silent, and only visible on reopen.
        var frameBorders = loadSession(beside: out)?.frameBorders ?? [:]
        let rollBase = (0..<3).map { c in median(bases.map { Float($0[c]) }) }
        print(String(format: "roll film base: R=%.4f G=%.4f B=%.4f", rollBase[0], rollBase[1], rollBase[2]))

        // --- encode ----------------------------------------------------------
        // Resolve the stems up front. This was computed twice per frame with
        // byte-identical code, the first result thrown away.
        func stemOf(_ g: [URL]) -> String {
            var stem = g[0].deletingPathExtension().lastPathComponent
            if let m = channelSuffix.firstMatch(in: stem,
                    range: NSRange(stem.startIndex..., in: stem)),
               let r = Range(m.range, in: stem) { stem.removeSubrange(r) }
            return stem
        }
        let jobs = frames.map { (g: $0, stem: stemOf($0)) }
            .filter { only == nil || only!.contains($0.stem) }

        // One frame per worker. The per-frame work is fully independent once the
        // border and roll base are known, and the machine was sitting at 82% of
        // ONE core while twelve were idle.
        //
        // Concurrency is bounded by MEMORY, not cores: a frame holds ~700 MB
        // live even after the in-place chain above, so eight at once would page
        // rather than scale. Derived from installed RAM so it does not have to be
        // re-guessed on a different machine.
        // Four, not one-per-core. Measured on this roll (11 frames, 12 cores):
        //   lanes  1     3     4     6     8    10
        //   sec   10.3   6.6   6.5   6.7   8.5   8.5
        // It stops scaling at 3-4 and gets WORSE beyond 6, because the work is
        // memory-bandwidth and disk bound, not compute bound: 2.1 GB of captures
        // in and 2.1 GB of masters out. Also still capped by installed RAM, since
        // each lane holds ~700 MB live.
        let perFrame = 800 << 20
        let lanes = max(1, min(jobs.count,
                               min(4, Int(ProcessInfo.processInfo.physicalMemory / 3) / perFrame)))
        let lanesEnv = ProcessInfo.processInfo.environment["HORIZON_LANES"].flatMap { Int($0) }
        let lanes2 = max(1, min(jobs.count, lanesEnv ?? lanes))
        print("encoding \(jobs.count) frame(s), \(lanes2) at a time")
        let lock = NSLock()
        var tLoad = 0.0, tDens = 0.0, tEnc = 0.0, tWrite = 0.0
        var done = 0
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: lanes2) { lane in
            var i = lane
            while i < jobs.count {
                defer { i += lanes2 }
                lock.lock(); let stop = failure != nil; lock.unlock()
                if stop { return }
                let (g, stem) = jobs[i]
                var t = Date()
                do {
                    var (p, w, h) = try frame(g, layout: layout)
                    let tL = -t.timeIntervalSinceNow; t = Date()
                    // p becomes D in place: the two are the same buffer from here.
                    densityInPlace(&p, dark: nil, response: response)
                    // DEV-EDGE: detected on THIS frame, from this frame alone. The
                    // roll rectangle is not consulted -- it was a roll-level
                    // statistic, which is the one thing this pipeline is not
                    // supposed to have, and it was measurably wrong on every
                    // frame of this roll (median 978 against a truth of 0-394,
                    // because the per-edge medians came from different frames).
                    let fb = useBorder ? detectEdges(p, w: w, h: h) : Border()
                    let base = perFrameBase
                        ? (estimateBase(p, w: w, h: h, border: fb, clipAt: clipAt)
                           ?? estimateBase(p, floor: floor))
                        : rollBase
                    let tD = -t.timeIntervalSinceNow; t = Date()
                    if debugBorder {
                        let dbg = out.deletingLastPathComponent()
                            .appendingPathComponent("debug")
                        try? FileManager.default.createDirectory(
                            at: dbg, withIntermediateDirectories: true)
                        writeBorderDebug(p, w: w, h: h, base: base, border: fb,
                                         clipAt: clipAt,
                                         to: dbg.appendingPathComponent(stem + ".border.jpg"))
                    }
                    imageDensityInPlace(&p, base: base)
                    let enc = cineon(p)
                    p = []                       // 377 MB, dead the moment it is encoded
                    let tE = -t.timeIntervalSinceNow; t = Date()
                    try writeMaster(enc, w: w, h: h,
                                    to: out.appendingPathComponent(stem + ".ntg.tif"))
                    let tW = -t.timeIntervalSinceNow
                    lock.lock()
                    tLoad += tL; tDens += tD; tEnc += tE; tWrite += tW
                    frameBorders[stem] = fb
                    done += 1
                    print("    \(stem)  L\(fb.left) T\(fb.top) R\(fb.right) B\(fb.bottom)")
                    print("  \(stem)  base [\(base.map { String(format: "%.3f", $0) }.joined(separator: " "))]")
                    progress?("inverting \(done)/\(jobs.count) — \(stem)")
                    lock.unlock()
                } catch {
                    lock.lock(); if failure == nil { failure = error }; lock.unlock()
                    return
                }
            }
        }
        if let failure { throw failure }

        // Record what produced these masters.
        let session = Session(layout: layout.rawValue,
                              // Only what was ACTUALLY used. Yours recorded a flat
                              // it had silently dropped, which is why the session
                              // claimed an LCC while the frames had none.
                              lcc: response != nil ? lccFiles.map(\.path) : [],
                              frameBorders: frameBorders,
                              perFrameBase: perFrameBase, useBorder: useBorder,
                              monochrome: monochrome)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(session) {
            try? d.write(to: sessionURL(beside: out))
        }
        let n2 = Double(frames.count)
        print(String(format: "per frame: decode %.2fs  density+base %.2fs  encode %.2fs  write %.2fs",
                     tLoad / n2, tDens / n2, tEnc / n2, tWrite / n2))
    }
}
