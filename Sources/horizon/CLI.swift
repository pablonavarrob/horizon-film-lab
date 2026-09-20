import AppKit
import Foundation
import UniformTypeIdentifiers

// CLI entry point, used to verify the Swift render against n2c_v5.py before
// any view code exists. The SwiftUI app is added on top of the same Master/Edit
// types, so anything verified here stays verified.
//
//   horizon --render MASTER.tif OUT.png [--dens N] [--cmy C M Y] [--tone NAME] [--high soft|hard] [--shadow soft|hard]

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(("horizon: " + m + "\n").data(using: .utf8)!)
    exit(1)
}

/// Returns true if a CLI verb was handled (caller should exit), false to fall
/// through to the GUI.
///
/// This must NOT be top-level code: `main.swift` top-level statements and a
/// SwiftUI `@main` App cannot coexist -- calling `App.main()` from top level
/// runs the process but never installs the app lifecycle, so no window is ever
/// created. That cost an hour; do not move this back.
func runCLI() -> Bool {
var args = Array(CommandLine.arguments.dropFirst())

func flagValues(_ name: String, _ count: Int) -> [String]? {
    guard let i = args.firstIndex(of: name), i + count < args.count else { return nil }
    let v = Array(args[(i + 1)...(i + count)])
    args.removeSubrange(i...(i + count))
    return v
}

// Alternative print model: a .cube film-print LUT instead of the RA-4 paper
// simulation. Takes a path, or a substring of a bundled LUT's name.
if let want = flagValues("--print-lut", 1)?.first {
    let direct = URL(fileURLWithPath: want)
    let url = FileManager.default.fileExists(atPath: want) ? direct
        : PrintLUT.bundled().first { $0.lastPathComponent.localizedCaseInsensitiveContains(want) }
        ?? URL(fileURLWithPath: "Resources/luts").appendingPathComponent(want)
    do {
        let lut = try PrintLUT.load(url)
        Paper.printLUT = lut
        print("print LUT: \(lut.name)  \(lut.size)^3  domain \(lut.domainMin)..\(lut.domainMax)")
    } catch { fail(error.localizedDescription) }
}

if args.contains("--mono") { Paper.monochrome = true }              // DEV-MONO
if let v = flagValues("--xhigh", 1)?.first.flatMap({ Double($0) }) { Paper.crossoverHigh = v }
if let v = flagValues("--xshadow", 1)?.first.flatMap({ Double($0) }) { Paper.crossoverShadow = v }
// DEV-ICC: an ICC applied AFTER our render. Refuses a profile that inverts,
// because that kind belongs on the raw captures via --icc-only instead.
if let want = flagValues("--output-icc", 1)?.first {
    do {
        let t = try ICCOnly.Transform.load(URL(fileURLWithPath: want))
        guard !t.invertsTone else {
            fail("\(t.name) INVERTS, so it is a negative-scanner profile; use --icc-only")
        }
        Paper.outputICC = t
        print("output ICC: \(t.name)  \(t.grid)^3  (on the rendered positive)")
    } catch { fail(error.localizedDescription) }
}
let toneArg = flagValues("--tone", 1)?.first
let densArg = flagValues("--dens", 1)?.first
let cmyArg = flagValues("--cmy", 3)
let maxEdgeArg = flagValues("--max-edge", 1)?.first

func grade(_ v: String?) -> Paper.Grade? {
    switch v?.lowercased() {
    case "soft": return .soft
    case "soft2", "soft+": return .soft2
    case "hard": return .hard
    case "hard2", "hard+": return .hard2
    case "std", "standard": return .standard
    default: return nil
    }
}
// DEV-CURVE, BEFORE the gradation clamp below: that clamp reads
// `Paper.gradationRange`, which the flag widens. Parsed after it, `--gradation 3`
// was silently clamped to 2 and the new top step could not be reached at all.
if args.contains("--new-curve") { Paper.newCurve = true }
// Shoulder shape, in the same spirit as --xhigh/--xshadow.
if let k = flagValues("--knee", 2) {
    Paper.kneeHigh = Double(k[0]) ?? Paper.kneeHigh
    Paper.kneeLow = Double(k[1]) ?? Paper.kneeLow
}
let gradArg = flagValues("--gradation", 1)?.first
let highArg = flagValues("--high", 1)?.first
let shadowArg = flagValues("--shadow", 1)?.first
var edit = Edit()
if let d = densArg, let v = Int(d) { edit.density = v }
if let c = cmyArg {
    let v = c.compactMap { Int($0) }
    if v.count == 3 { edit.cyan = v[0]; edit.magenta = v[1]; edit.yellow = v[2] }
}
if let g = gradArg, let v = Int(g) { edit.gradation = min(max(v, Paper.gradationRange.0), Paper.gradationRange.1) }
if let g = grade(highArg) { edit.high = g }
if let g = grade(shadowArg) { edit.shadow = g }
if let t = toneArg {
    guard let b = Paper.ToneButton.allCases.first(where: {
        $0.rawValue.lowercased() == t.lowercased()
            || $0.label.lowercased().replacingOccurrences(of: " ", with: "-") == t.lowercased()
    }) else { fail("unknown tone '\(t)'; options: "
                   + Paper.ToneButton.allCases.map(\.rawValue).joined(separator: ", ")) }
    edit.apply(b)
}

// --invert FOLDER [--layout mono3|rgb3|rgb1|mono1] [--lcc DIR] [--only STEM]
//                 [--no-border] [--debug-border] [--per-frame-base] [--out DIR]
//            [--per-frame-base] [--out DIR]
if let i = args.firstIndex(of: "--invert"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1])
    // LCC/flat captures excluded, as `Invert.run` excludes them. Counting a flat
    // changes the file count's parity, and parity is what decides one-shot from
    // three-shot, so one flat in the folder flipped the layout.
    let exts: Set<String> = ["tif", "tiff", "png"]
    let caps = ((try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil)) ?? [])
        .filter { exts.contains($0.pathExtension.lowercased()) && !Invert.isLCC($0) }
    // Same suggestion the GUI seeds its picker from, so the two never disagree.
    // On the CLI `--layout` IS the operator's choice; without it, the suggestion
    // stands in for the picker.
    let suggestion = Invert.suggestLayout(caps)
    let layout = flagValues("--layout", 1)?.first.flatMap(Invert.Layout.init(rawValue:))
        ?? suggestion?.layout ?? .rgb3
    let mono = args.contains("--mono") || (suggestion?.monochrome ?? false)
    // Defaults TRUE, to match the GUI, which always passes true. It defaulted
    // false, so every CLI measurement silently used a ROLL base and did not
    // reproduce the app -- every frame reported the same base and nobody noticed.
    // `--roll-base` opts out; `--per-frame-base` is kept as a no-op for old scripts.
    let perFrameBase = !args.contains("--roll-base")
    let useBorder = !args.contains("--no-border")
    let onlyStem = flagValues("--only", 1)?.first
    let debugBorder = args.contains("--debug-border")
    let lccDir = flagValues("--lcc", 1)?.first.map { URL(fileURLWithPath: $0) }
    let lccFiles = lccDir.flatMap {
        (try? FileManager.default.contentsOfDirectory(at: $0,
            includingPropertiesForKeys: nil))?
            .filter { ["tif","tiff","png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    let outDir = flagValues("--out", 1)?.first.map { URL(fileURLWithPath: $0) }
        ?? dir.appendingPathComponent(".cache")
    do {
        try Invert.run(dir: dir, layout: layout, perFrameBase: perFrameBase,
                       out: outDir, only: onlyStem.map { Set([$0]) },
                       useBorder: useBorder, lcc: lccFiles,
                       debugBorder: debugBorder, monochrome: mono)
    } catch { fail(error.localizedDescription) }
    return true
}

// DEV-ICC: --icc-only PROFILE CAPTURES OUT   (see ICCOnly.swift)
if let i = args.firstIndex(of: "--icc-only"), i + 3 < args.count {
    let prof = URL(fileURLWithPath: args[i + 1])
    let dir = URL(fileURLWithPath: args[i + 2])
    let out = URL(fileURLWithPath: args[i + 3])
    let exts: Set<String> = ["tif", "tiff", "png"]
    let all = ((try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil)) ?? [])
        .filter { exts.contains($0.pathExtension.lowercased()) && !Invert.isLCC($0) }
    guard let layout = Invert.suggestLayout(all)?.layout else {
        fail("cannot read \(dir.lastPathComponent)")
    }
    let groups = Invert.group(all, layout: layout)
    guard let first = groups.first else { fail("no frames in \(dir.lastPathComponent)") }
    let which = flagValues("--only", 1)?.first
    let pick = which.flatMap { w in groups.first { $0[0].lastPathComponent.contains(w) } } ?? first
    do {
        try ICCOnly.render(frame: pick, layout: layout, profile: prof, to: out,
                           maxEdge: maxEdgeArg.flatMap { Int($0) },
                           scale: ICCOnly.Scale(rawValue:
                               flagValues("--icc-scale", 1)?.first ?? "global") ?? .global)
    } catch { fail(error.localizedDescription) }
    return true
}

// The editor's redraw cost, with no file encoding in the number. This is the
// path a slider drag runs, so it is the one that has to stay fast.
//
// 1233x824: ~25 ms on the built-in model, ~9 ms through an ICC. The built-in
// is the SLOWER of the two because it evaluates the paper curve per pixel --
// several transcendentals per channel -- where the ICC is a trilinear fetch.
// This comment read "~6 ms / ~12 ms", which no build measured: caching the
// endpoints and the aim took the same frame from 31.2 to 25.3 ms built-in and
// 16.7 to 8.8 ms through the ICC, so the old figures were already stale by 5x
// on one path. Re-measure before quoting a number here.
if let v = flagValues("--time-redraw", 1), let p = v.first {
    do {
        let m = try Master.load(URL(fileURLWithPath: p), maxEdge: FrameItem.previewEdge,
                                frame: nil)
        var graded = Edit(); graded.density = 6; graded.high = .hard2; graded.shadow = .soft2
        for (label, e) in [("neutral", Edit()), ("hard/soft", graded)] {
            _ = try m.cgImage(e, bits: 8)                     // warm
            let t0 = Date()
            for _ in 0..<5 { _ = try m.cgImage(e, bits: 8) }
            print(String(format: "%dx%d  %-10@ %.1f ms/redraw", m.width, m.height,
                         label as NSString, -t0.timeIntervalSinceNow / 5 * 1000))
            // DEV-SCOPE: the readouts are a second pass over the preview, so keep
            // their cost visible next to the render's.
            let img = try m.cgImage(e, bits: 8)
            var t1 = Date()
            for _ in 0..<5 { _ = Scopes.of(img, mask: nil, anchor: 0.5) }
            let th = -t1.timeIntervalSinceNow / 5 * 1000
            t1 = Date()
            for _ in 0..<5 { _ = Parade.of(img, mask: nil) }
            print(String(format: "            histogram %.1f ms   parade %.1f ms",
                         th, -t1.timeIntervalSinceNow / 5 * 1000))
        }
    } catch { fail(error.localizedDescription) }
    exit(0)
}

if args.contains("--check-grade") {
    // The gates that still mean something. `checkMonotone` and `checkToneMap`
    // went with the log-domain paper path they were testing.
    let sel = Master.checkSelect()
    print("quickselect vs sorted(): \(sel.cases) cases, \(sel.wrong) wrong")
    guard sel.wrong == 0 else { fail("quickselect is wrong") }
    // THE WHOLE VALUE PATH MUST STAY MONOTONE AND IN RANGE, for every control
    // combination the panel can produce. `Master.curveValue` is literally what
    // `render16` folds into its table, so this checks the arithmetic that renders
    // rather than a paraphrase of it. A non-monotone curve inverts the picture
    // locally; one that collapses posterises it.
    //
    // It replaced a "levels span" sweep, which measured the gap between the
    // endpoints. That became meaningless when the last control stopped moving an
    // endpoint -- it would have reported a constant 0.70 for ever.
    var worstDrop = 0.0, dropAt = "none", worstOut = 1.0, outAt = "none", cases = 0
    var drOpen = 1.0
    // DEV-CURVE: sweep BOTH models. The invariants belong to the control surface,
    // not to one configuration of it, and a flag that only the off-path is tested
    // against is a flag that breaks the day it is switched on.
    let curveModes = [false, true]
    for curveMode in curveModes {
    Paper.newCurve = curveMode
    for d in [-50, -20, -7, 0, 7, 20, 50] {
        for g in -3...3 {
            for hi in Paper.Grade.allCases {
                for sh in Paper.Grade.allCases {
                    for cmy in [0, -20, 20] {
                        var e = Edit(); e.density = d; e.gradation = g
                        e.high = hi; e.shadow = sh
                        e.cyan = cmy; e.magenta = -cmy; e.yellow = cmy
                        let aim = Master.aimTarget(.init(icc: nil, lut: nil, mono: false), e)
                        let ks = Master.toneSlopes(e, newCurve: Paper.newCurve)
                        let off = Master.cmyOffsets(e)
                        cases += 1
                        for (ci, o) in [off.0, off.1, off.2].enumerated() {
                            var prev = -1.0, lo = 2.0, hiV = -1.0
                            for i in 0...256 {
                                let v = Master.curveValue(Double(i) / 256,
                                                          lo: 0.05, hi: 0.75, gamma: 0.4,
                                                          aim: aim, slopes: ks, offset: o,
                                                          shoulder: Paper.newCurve)
                                guard v >= -1e-12, v <= 1 + 1e-12 else {
                                    fail("value \(v) out of range, channel \(ci), d \(d) g \(g) cmy \(cmy)")
                                }
                                if v < prev - 1e-12, prev - v > worstDrop {
                                    worstDrop = prev - v
                                    dropAt = "ch \(ci) d \(d) g \(g) h \(hi.short) s \(sh.short) cmy \(cmy)"
                                }
                                prev = v; lo = min(lo, v); hiV = max(hiV, v)
                            }
                            if hiV - lo < worstOut {
                                worstOut = hiV - lo
                                outAt = "ch \(ci) d \(d) g \(g) h \(hi.short) s \(sh.short) cmy \(cmy)"
                            }
                            // DEV-CURVE: the shoulder is asymptotic at the TOP
                            // ONLY, so the white end must stay open. The BLACK end
                            // is expected to reach 0 -- `Paper.kneeLow = 1.0`
                            // disables the lower roll-off on purpose, so blacks
                            // keep their full slope. This check asserted both ends
                            // and correctly failed the moment the curve became
                            // asymmetric.
                            //
                            // THIS IS THE STRETCHED DOMAIN ONLY. It does not mean
                            // the OUTPUT cannot clip: the terminator has its own
                            // toe, which is why the Contrast range tops out at +3
                            // -- at +4 the stretched value still never reached an
                            // end while 2.1% of output pixels were crushed to
                            // black. Checking output needs an image, which this
                            // gate has not got.
                            if Paper.newCurve, cmy == 0 {
                                if hiV >= 1 {
                                    fail("the shoulder reached white (\(hiV)) at d \(d) g \(g) h \(hi.short) s \(sh.short)")
                                }
                                drOpen = min(drOpen, 1 - hiV)
                            }
                        }
                    }
                }
            }
        }
    }
    }
    Paper.newCurve = false
    print(String(format: "value path over %d control combinations (both curve models): worst backward step %.2e (%@)",
                 cases, worstDrop, dropAt))
    guard worstDrop == 0 else { fail("the value path is not monotone at \(dropAt)") }
    print(String(format: "   narrowest output range %.4f (%@)", worstOut, outAt))
    guard worstOut > 0.02 else { fail("the value path collapses to \(worstOut) at \(outAt)") }
    print(String(format: "   DR shoulder stays open (stretched domain): %.2e from an end", drOpen))
    guard drOpen > 0 else { fail("DR mode reached an end") }

    // A COLOUR KEY MUST SHIFT EVERY TONE BY THE SAME AMOUNT. This is the printer
    // light property, and it is what C/M/Y did NOT have while it sat on the
    // endpoints: measured then, +6 magenta moved the green channel -20.6 codes in
    // the shadows against -81.9 in the midtones and -93.2 in the highlights,
    // because the offset landed upstream of the exposure exponent and of the 0/1
    // clamp. Checked away from the clamps, where a constant shift is expressible.
    var spread = 0.0, spreadAt = "none"
    for keys in [-12, -6, -1, 1, 6, 12] {
        for g in -3...2 {
            var e = Edit(); e.gradation = g
            var z = e; z.magenta = keys
            let aim = Master.aimTarget(.init(icc: nil, lut: nil, mono: false), e)
            let ks = Master.toneSlopes(e)
            let off = Master.cmyOffsets(z).1
            var lo = 2.0, hi = -2.0
            for i in 20...236 {                       // away from both clamps
                let x = Double(i) / 256
                let a = Master.curveValue(x, lo: 0.05, hi: 0.75, gamma: 0.4,
                                          aim: aim, slopes: ks, offset: 0)
                let b = Master.curveValue(x, lo: 0.05, hi: 0.75, gamma: 0.4,
                                          aim: aim, slopes: ks, offset: off)
                // only where neither end is sitting on a clamp
                guard a > 1e-6, a < 1 - 1e-6, b > 1e-6, b < 1 - 1e-6 else { continue }
                lo = min(lo, b - a); hi = max(hi, b - a)
            }
            if hi > lo, hi - lo > spread {
                spread = hi - lo; spreadAt = "\(keys)M g \(g)"
            }
        }
    }
    print(String(format: "colour key shift varies across tones by %.2e (%@)",
                 spread, spreadAt))
    guard spread < 1e-9 else {
        fail("a colour key acts differently at different tones at \(spreadAt)")
    }

    // CONTRAST MUST PIN THE AIM. This is what makes it independent of exposure:
    // the slope pivots on the aim, so v = aim maps to aim for every setting. If
    // this ever fails, a contrast press moves the exposure again.
    var pinned = 0.0, pinAt = "none", combos = 0
    for aim in [0.05, 0.25, 0.4993, 0.75, 0.95] {
        for g in -3...2 {
            for hi in Paper.Grade.allCases {
                for sh in Paper.Grade.allCases {
                    var e = Edit(); e.gradation = g; e.high = hi; e.shadow = sh
                    let k = Master.toneSlopes(e)
                    combos += 1
                    let off = abs(Master.tone(aim, aim: aim, lo: k.lo, hi: k.hi) - aim)
                    if off > pinned {
                        pinned = off
                        pinAt = "aim \(aim) g \(g) h \(hi.short) s \(sh.short)"
                    }
                    // And it must stay monotone, or the picture inverts locally.
                    guard k.lo > 0, k.hi > 0 else {
                        fail("tone slope <= 0 at \(pinAt)")
                    }
                }
            }
        }
    }
    print(String(format: "contrast pins the aim over %d combinations: worst %.2e (%@)",
                 combos, pinned, pinAt))
    guard pinned < 1e-12 else { fail("contrast moved the aim by \(pinned) at \(pinAt)") }

    // AND THE EXPOSURE MUST LAND THE METERED POINT ON THE DENSITY-OFFSET AIM,
    // to within floating point, for every metered position the frame might have.
    var offAim = 0.0, offAt = "none", checked = 0
    var worstStep = 0.0, stepAt = "none"
    let perPress = pow(10.0, Paper.densStep)          // exposure ratio, one press
    for aim in [0.25, 0.4993, 0.75] {
        for v0 in [0.03, 0.06, 0.10, 0.20, 0.40, 0.70, 0.90, 0.97] {
            for d in [-20, -7, -1, 0, 1, 7, 20] {
                var e = Edit(); e.density = d
                let v = min(max(v0, 0.02), 0.98)
                let want = aim * pow(10.0, -Double(d) * Paper.densStep)
                let target = min(max(want, 1e-4), 0.999)
                let gam = log(target) / log(v)
                checked += 1
                guard gam.isFinite, gam > 0 else {
                    fail("exponent \(gam) at aim \(aim) v \(v0) d \(d)")
                }
                guard want > 1e-4, want < 0.999 else { continue }
                let off = abs(pow(v, gam) - target)
                if off > offAim {
                    offAim = off; offAt = "aim \(aim) v \(v0) d \(d)"
                }
                // One press must be worth exactly one `densStep` of exposure at
                // the metered point -- a tenth of a stop, so the key is fine
                // enough to be useful and never overshoots.
                if d == 1 {
                    let g0 = log(min(max(aim, 1e-4), 0.999)) / log(v)
                    let ratio = pow(v, gam) / pow(v, g0)
                    let step = abs(ratio - 1.0 / perPress)
                    if step > worstStep {
                        worstStep = step; stepAt = "aim \(aim) v \(v0)"
                    }
                }
                _ = e
            }
        }
    }
    print(String(format: "exposure lands on the aim over %d combinations: worst miss %.2e (%@)",
                 checked, offAim, offAt))
    guard offAim < 1e-9 else { fail("placement misses the aim by \(offAim) at \(offAt)") }
    print(String(format: "one density press = %.3f stop, exact to %.2e (%@)",
                 Paper.densStep / log10(2.0), worstStep, stepAt))
    guard worstStep < 1e-9 else {
        fail("a density press moved exposure by the wrong amount at \(stepAt)")
    }

    // Border detection, against GROUND TRUTH rather than against a baseline file.
    //
    // There used to be `verify/border-baseline-rollA.txt`: the per-frame insets
    // one 33-frame roll produced, diffed after any change. That check could only
    // ever say "unchanged", never "correct"; it died the moment the roll moved;
    // and it made one roll the definition of right. This synthesises the rebate,
    // so the answer is known by construction and the sweep covers geometry and
    // film bases no single roll contains.
    //
    // GET THE PIPELINE STAGE RIGHT. `detectEdges` runs on density measured
    // against the CLEAR GATE, before the base is known -- that is what
    // `provisionalBase` is for. So the rebate reads at FILM BASE DENSITY, not near
    // zero, and it is base-relative per channel (an orange mask is denser in blue).
    // Writing the rebate near zero instead put every sample under `satFloor`,
    // where `lineStats` correctly discards it as saturated, and the whole sweep
    // read as a detector failure when it was a generator failure.
    //
    // Insets are FRACTIONS so every case stays inside `edgeCap` at every size.
    var frames = 0, worstErr = 0, worstCase = "none", ate = 0, ateCase = "none"
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rnd() -> Float {                       // deterministic; a gate must repeat
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Double(seed >> 40) / Double(1 << 24)) - 0.5
    }
    // No tiny sizes: a side can only close if `inset + edgeRun <= edgeCap * n`,
    // so at 400 px an inset over 24 px is UNDETECTABLE BY CONSTRUCTION and the
    // walk correctly returns 0 rather than guessing. Real captures are 4896x3264
    // (cap 587/391), so this never binds in practice -- but it does mean border
    // detection must run at full resolution, which `run` does (`Dfull`).
    for (w, h) in [(1224, 816), (816, 1224), (900, 900), (1400, 700)] {
        for frac in [(0.0, 0.0, 0.0, 0.0), (0.05, 0.04, 0.05, 0.04),
                     (0.09, 0.07, 0.02, 0.05), (0.08, 0.08, 0.08, 0.08)] {
            for base in [[Float(0.18), 0.30, 0.44], [Float(0.42), 0.61, 0.83]] {
                for scene in [(0.12, 0.08), (0.45, 0.40), (0.70, 0.50)] {
                    for grain in [Float(0.006), Float(0.030)] {
                        let l = Int(Double(w) * frac.0), t = Int(Double(h) * frac.1)
                        let r = Int(Double(w) * frac.2), b = Int(Double(h) * frac.3)
                        var p0 = [Float](repeating: 0, count: w * h)
                        var p1 = p0, p2 = p0
                        // Structure, not noise: the detector reads per-line IQR, so
                        // flat picture must not read as rebate. The texture
                        //   sin(fx*37)*cos(fy*23) + 0.6*sin((fx+fy)*113)
                        // is SEPARABLE via the angle-sum identity, so it costs six
                        // 1-D tables instead of three trig calls per pixel. Exact,
                        // not an approximation -- but measured, it bought nothing:
                        // the cost is in `detectEdges` and the pixel writes, not
                        // the trig. Kept because it is not worse, not for speed.
                        let pw = max(w - l - r, 1), ph = max(h - t - b, 1)
                        var ax = [Float](repeating: 0, count: w)
                        var cx = ax, ex = ax
                        for x in 0..<w {
                            let fx = Float(x - l) / Float(pw)
                            ax[x] = sin(fx * 37); cx[x] = sin(fx * 113)
                            ex[x] = cos(fx * 113)
                        }
                        var by = [Float](repeating: 0, count: h)
                        var dy = by, fy2 = by
                        for y in 0..<h {
                            let fy = Float(y - t) / Float(ph)
                            by[y] = cos(fy * 23); dy[y] = cos(fy * 113)
                            fy2[y] = sin(fy * 113)
                        }
                        let amp = Float(scene.1) * 0.5
                        p0.withUnsafeMutableBufferPointer { q0 in
                        p1.withUnsafeMutableBufferPointer { q1 in
                        p2.withUnsafeMutableBufferPointer { q2 in
                            for y in 0..<h {
                                let inRow = y >= t && y < h - b
                                for x in 0..<w {
                                    let inside = inRow && x >= l && x < w - r
                                    var tex: Float = 0
                                    if inside {
                                        tex = ax[x] * by[y]
                                            + 0.6 * (cx[x] * dy[y] + ex[x] * fy2[y])
                                    }
                                    // Rebate is base ALONE; picture is base plus
                                    // scene. Both strictly above `satFloor`.
                                    let lift = inside ? Float(scene.0) + amp * tex : 0
                                    let i = y * w + x
                                    q0[i] = base[0] + lift + grain * rnd()
                                    q1[i] = base[1] + lift + grain * rnd()
                                    q2[i] = base[2] + lift + grain * rnd()
                                }
                            }
                        }}}
                        let D = [p0, p1, p2]
                        let got = Invert.detectEdges(D, w: w, h: h)
                        let want = [l, t, r, b]
                        let have = [got.left, got.top, got.right, got.bottom]
                        frames += 1
                        let dim = [w, h, w, h]
                        for i in 0..<4 {
                            // The two directions are NOT symmetric, so they are
                            // scored apart. Missing rebate leaves film base inside
                            // the mask and biases every statistic taken through it,
                            // including the base estimate itself. Over-detecting
                            // only costs sampling area -- the border masks
                            // statistics, it does not crop. So: zero tolerance one
                            // way, a bounded allowance the other.
                            let d = have[i] - want[i]
                            if -d > worstErr {
                                worstErr = -d
                                worstCase = "\(w)x\(h) want \(want) base \(base[0]) D \(scene.0) grain \(grain) -> \(have)"
                            }
                            let pc = Int(100.0 * Double(max(d, 0)) / Double(dim[i]))
                            if pc > ate {
                                ate = pc
                                ateCase = "\(w)x\(h) want \(want) D \(scene.0) -> \(have)"
                            }
                        }
                    }
                }
            }
        }
    }
    print(String(format: "border vs ground truth: %d synthetic frames, worst MISSED rebate %d px",
                 frames, worstErr))
    if worstErr > 0 { print("   worst: \(worstCase)") }
    print("   most picture eaten: \(ate)% of a side  (\(ateCase))")
    guard worstErr == 0 else {
        fail("border detection missed \(worstErr) px of rebate: \(worstCase)")
    }
    // 5% of a side. Over-detection is the safe direction and the code says so, but
    // unbounded is not safe -- `edgeCap` alone would let 12% go silently.
    guard ate <= 5 else { fail("border detection ate \(ate)% of a side: \(ateCase)") }
    return true
}


guard let i = args.firstIndex(of: "--render"), i + 2 < args.count else {
    if args.contains("--help") || args.contains("-h") {
        print("Horizon [FOLDER]                        open the editor")
        print("Horizon --render MASTER.tif OUT.{tif,jpg,png} [--dens N] [--cmy C M Y]")
        print("        [--tone NAME] [--high soft|hard] [--shadow soft|hard] [--mono]")
        print("        [--max-edge N] [--crop] [--output-icc PROFILE] [--print-lut NAME]")
        print("Horizon --invert FOLDER [--layout mono3|rgb3|rgb1|mono1] [--out DIR]")
        print("        [--lcc DIR] [--only STEM] [--no-border] [--debug-border] [--mono]")
        print("Horizon --icc-only PROFILE CAPTURES OUT   raw captures through a profile")
        print("        [--new-curve]     DEV-CURVE: shouldered contrast model")
        print("Horizon --check-grade                    run the gates")
        return true
    }
    launchFolder = args.first.flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) }
    return false
}
let inURL = URL(fileURLWithPath: args[i + 1])
let outURL = URL(fileURLWithPath: args[i + 2])

// 16-bit TIFF is the archival render; JPEG is the delivery file. PNG stays
// available because it is lossless AND 16-bit, which makes it the right format
// for diffing against the Python reference.
let outType: UTType = {
    switch outURL.pathExtension.lowercased() {
    case "tif", "tiff": return .tiff
    case "jpg", "jpeg": return .jpeg
    case "png": return .png
    default: fail("unknown output extension '\(outURL.pathExtension)'; use tif, jpg or png")
    }
}()

do {
    let t0 = Date()
    // Same frame rectangle the editor uses: session.json sits one level above
    // the cache directory the master lives in.
    var frameRect: Invert.Border? = nil
    var statsGate: Invert.Border? = nil
    let sessURL = inURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("session.json")
    if let d = try? Data(contentsOf: sessURL),
       let sess = try? JSONDecoder().decode(Invert.Session.self, from: d) {
        let stem = inURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".ntg", with: "")
        frameRect = sess.frameBorders[stem]
        // DEV-GATE: the whole roll's gate, so a CLI render measures what the
        // editor measures. Reading one frame's own rectangle here made the CLI
        // disagree with the app on exactly the frames whose detection failed.
        let detector = Invert.Border.gate(of: sess.frameBorders)
        statsGate = detector
        // The roll's film type, so the CLI renders a B&W roll as B&W without
        // being told. --mono still forces it for a roll with no session.
        if sess.monochrome { Paper.monochrome = true }
    }
    let m = try Master.load(inURL, maxEdge: maxEdgeArg.flatMap { Int($0) },
                            frame: statsGate,
                            crop: args.contains("--crop") ? frameRect : nil)
    let loaded = Date()
    try m.write(edit, to: outURL, as: outType)
    let (lo, hi) = m.directLevels(edit)
    print(String(format: "%dx%d  levels lo=[%.3f %.3f %.3f] hi=[%.3f %.3f %.3f]  tone=%@",
                 m.width, m.height, lo[0], lo[1], lo[2], hi[0], hi[1], hi[2],
                 edit.toneSummary))
    print(String(format: "load %.2fs  render+write %.2fs",
                 loaded.timeIntervalSince(t0), Date().timeIntervalSince(loaded)))
} catch {
    fail(error.localizedDescription)
}
return true
}

/// Folder to open at launch, set by runCLI().
nonisolated(unsafe) var launchFolder: URL?
