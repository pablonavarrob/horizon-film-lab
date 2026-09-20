import Foundation

/// RA-4 print paper rendering, and the operator controls that drive it.
///
/// Every constant is published:
///  - RA-4 colour paper datasheet AF3-212E s.16 -> curve, Dmin, Dmax
///  - Kodak E-4053: aim print measures 0.80 R/G/B Status A   -> mid-grey anchor
///  - Kodak E-4014: "lower D-max for blue than for red and green"
///  - Minilab service doc PP3-B177E s.2.1.2: C/M/Y key step 8%, density key 15%
///
/// `n2c_v5.py` is NOT an oracle for this: both halves have since diverged.
enum Paper {

    // Published curve, relative log exposure, Status A. AF3-212E s.16.
    // Third-party measured sensitometry (agx-emulsion) was tried and reverted:
    // its logE origin, per-channel Dmin and shadow ordering all disagreed with
    // the datasheet in ways that could not be adjudicated.
    static let logE: [Double] = [-0.9, -0.8, -0.7, -0.6, -0.5, -0.4, -0.3, -0.2, -0.1,
                                 0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    static let density: [Double] = [0.060, 0.064, 0.078, 0.102, 0.178, 0.224, 0.360,
                                    0.526, 0.771, 1.083, 1.395, 1.688, 1.948, 2.148,
                                    2.298, 2.376, 2.452, 2.452, 2.458]

    static let dMin = 0.060
    static let dMax: (Double, Double, Double) = (2.66, 2.53, 2.48)   // R > G > B
    /// Keeps per-channel divergence in the shoulder, where the datasheet shows
    /// it. Scaling the whole curve instead smears 0.056 D into mid-grey --
    /// three times the published mid-scale figure, i.e. visibly cyan midtones.
    static let shoulderN = 3.0

    /// Where mid-grey sits on the paper's exposure axis: the logE at which the
    /// published curve reads print density 0.80, the Kodak E-4053 aim print.
    ///
    /// Moving it to -0.20 to make renders lighter was tried and reverted -- it
    /// slides mid-grey onto the curve's toe, where the highlight slope is 0.67
    /// against the shadow's 2.45, so the tone controls lose their authority.
    /// Exposure placement belongs to the levels stretch, not to this anchor.
    static let midGreyLogE = -0.091

    /// The reference minilab's colour characteristic: warm highlights, cyan-leaning
    /// shadows, neutral mid-grey. A per-channel contrast difference pivoted on
    /// mid-grey -- physically, the red-sensitive layer running at a different
    /// contrast from the blue.
    ///
    /// AIMED FOR, not derived, and the research says that is the honest way
    /// round: AF3-212E draws G and B with byte-identical control points below
    /// D~0.76, its R runs HIGHER in the toe (cyan highlights, the opposite of
    /// the target), and the look is a SCANNER characteristic -- the manufacturer
    /// calibrates these printers from undisclosed LUTs. No paper curve gives us it.
    /// The crossover itself is documented: Kodak Alaris Silver Halide White
    /// Paper (2015) Fig. 8, per-channel gamma R 4.02 / G 3.10 / B 3.38 at D~1.0.
    ///
    /// ASYMMETRIC because the eye is not linear in density: 0.10 D is worth ~15
    /// codes at D=0.5 but only ~3.6 at D=2.0, so the highlight half dominates
    /// visually despite being 3-4x smaller. Calibrated against three independent
    /// measurements of real minilab output (R-G in sRGB codes): ungraded scan
    /// -2.5..-4.4 shadow / +4.5..+6.2 highlight, measured minilab ICC profiles
    /// -3.0 / +6.0. A ColorChecker on the reference scanner says -13.6, the outlier,
    /// confounded by Portra's own crossover plus the machine's AWB.
    ///
    /// THE SIGNATURE IS SUBTLE -- a few code values on the neutral axis, not
    /// fifteen. The strong warm look people mean is not in the neutral axis.
    ///
    /// Either value at 0 disables that half. Both at 0 gives the bare curve.
    nonisolated(unsafe) static var crossoverHigh = 0.150   // highlight side
    // Ladder on the synthetic wedge, R-B in codes. Nothing is published, so
    // every value on it is a judgement:
    //   0.15/0.06  highlight +13..+18  shadow -5..-6   <- HERE
    //   0.26/0.09  highlight +26..+29  shadow -6..-7
    //   0.50/0.18  highlight +46..+52  shadow -11      (reads as a cast)
    //
    // KEEP THE MARKER ON THE VALUE THE CODE CARRIES. It has been wrong twice,
    // which is how the crossover once ran at half its intended strength and how
    // a fitted value once survived a revert.
    //
    // FITTED TO THE ICC AND REJECTED ON SIGHT. 0.35/0.18 cut the residual
    // against the colleague's ICC by 37% on BOTH rigs (roll A 3.71 -> 2.33, roll
    // B 7.00 -> 4.47), so it transferred rather than fitting one roll -- but on
    // the wedge 0.35 reads R-B +45, which the ladder above calls a cast. The
    // numbers and the eye disagreed and the eye won.
    //
    // WHAT IS STRUCTURALLY WRONG, whatever the magnitude: the ICC's warmth PEAKS
    // in the upper midtones (b* +6.4 at L*50) and FALLS toward paper white
    // (+2.6 at L*90). A slope tilt pivoted on mid-grey diverges monotonically,
    // so ours necessarily peaks at the white end. That is the floor under the
    // 2.33 residual; closing it needs a non-monotone divergence, not a bigger
    // number.
    nonisolated(unsafe) static var crossoverShadow = 0.060 // shadow side

    /// The two ends need DIFFERENT channel patterns, because "warm highlights"
    /// and "cyan shadows" are not the same axis:
    ///
    ///   highlight side  R up, B down, G fixed  -> pure yellow-blue
    ///   shadow side     R down, G and B up     -> pure cyan-red
    ///
    /// Each vector sums to zero, so neither end shifts luminance, only hue.
    ///
    /// Fitted on the hue angle of near-neutral pixels in REAL frames, not the
    /// synthetic wedge -- the inversion's own residual adds to the paper's and
    /// the wedge cannot see it. On 11 frames, high-mid / highlight hue:
    ///   R 0.85  111 / 103  green / yellow
    ///   R 1.00   89 /  91  yellow / yellow   <- here
    ///   R 1.30   42 /  65  orange / orange
    /// A red-only tilt was tried first and read as a red cast (hue 19-20).
    /// [0.5, 0.5, -1] was tried against [1, 0, -1] and measured RMS 3.76 to
    /// 2.34, so "yellow needs R and G moving together" does not survive.
    static func channelTilt(_ channel: Int, highlight: Bool) -> Double {
        if highlight { return [1.00, 0.00, -1.00][channel] }
        return [1.00, -0.80, -0.20][channel]
    }

    // Cineon / SMPTE 268M
    static let codeOffset = 95.0, codeSlope = 500.0, maxCode = 1023.0

    // The published key steps are a percentage of exposure, not a density.
    /// One colour key press, in log10 exposure. log10(1.05), i.e. 5% of exposure
    /// or 0.070 stops.
    ///
    /// The service doc's figure is 8% — but it says "NORMALLY SET AT 8%", i.e. it
    /// is a configurable key on the machine, not a constant of it. 8% put one
    /// press at 0.111 stops, which made 12M — the kind of number a Frontier
    /// operator actually dials for a green cast — worth 1.33 stops of magenta.
    /// That is far more than any cast correction wants, so the panel could only
    /// fix gross casts, never place a subtle one. At 5%, 12M is 0.85 stops: firm,
    /// and in the range a real correction lives in.
    ///
    /// Most of the coarseness was never the step, though. C/M/Y used to offset the
    /// per-channel ENDPOINTS, upstream of the exposure exponent, which amplified
    /// it ~4x — one key moved the midtones 14 output codes. Moving it after the
    /// exponent (`Master.cmyOffsets`) took that to 3.7 codes on its own, and this
    /// step takes it to about 2.3.
    static let cmyStep = 0.02118930  // log10(1.05), 5% of exposure
    /// One density key press, in log10 exposure. log10(2)/10, i.e. exactly a
    /// TENTH OF A STOP.
    ///
    /// Was log10(1.15) = 0.0607, the machine's documented 15% key, which is 0.2
    /// stops -- measured too coarse in use: the useful range around a placed
    /// exposure is well under a stop, so the first press already overshot. A tenth
    /// gives half a stop across five presses and keeps the full +-50 range at +-5
    /// stops, which is more than the levels domain can use anyway.
    static let densStep = 0.03010300 // log10(2)/10, one tenth of a stop
    /// Key travel. `cmyRange` went 20 -> 30 with the finer `cmyStep`, so the panel
    /// keeps the same total authority it had at 8% (2.1 stops against 2.2) while
    /// each press does a third less.
    static let cmyRange = 30, densRange = 50

    /// Gradation is TWO independent axes, not one preset. The machine's seven
    /// buttons are the useful corners of that square -- on the real one you hold
    /// Highlight Soft with Shadow Hard, which one enum cannot express.
    enum Grade: Int, CaseIterable, Codable, Identifiable {
        case soft2 = -2, soft = -1, standard = 0, hard = 1, hard2 = 2
        var id: Int { rawValue }
        var short: String {
            switch self {
            case .soft2: return "SOFT+"; case .soft: return "SOFT"
            case .standard: return "STD"
            case .hard: return "HARD"; case .hard2: return "HARD+"
            }
        }
        /// Mixed case, as the reference machine labels its controls.
        var title: String {
            switch self {
            case .soft2: return "Soft +"; case .soft: return "Soft"
            case .standard: return "Std"
            case .hard: return "Hard"; case .hard2: return "Hard +"
            }
        }
    }

    /// A press toward SOFT moves the picture ~3x as far as one toward HARD,
    /// because the hard direction saturates against paper white (p99 sits 4
    /// codes off the 248 ceiling at Hard+) while the soft direction has the
    /// whole range to fall through. Measured p99 steps before damping
    /// +17 +17 +8 +5; damping the soft side alone evens them to +10 +10 +8 +5.
    /// Swept for the evenness of the lift AND contrast ladders, which saturate
    /// differently, so no value evens both: 1.0 -> 6.0 combined SD, 0.6 -> 4.3
    /// (here), 0.5 -> 4.1.
    static let softDamp = 0.6

    /// Gradation Selection step, applied to BOTH sides equally -- it is the
    /// "main gradation", not a regional trim. Hard2 = +2 steps, Soft3 = -3.
    static let gradationStep = 0.12

    // DEV-DRANGE WAS BUILT AND IS REMOVED, and the reason is worth keeping.
    //
    // It widened the endpoints to p0.001/p99.999 to recover the scene's own
    // extremes -- a median 14.3% of extra span above the white point and 32.4% on
    // the worst frames, against 1.3% below the black point, because film base is a
    // hard floor and speculars are not. That measurement is real and is why the
    // shoulder below exists at all.
    //
    // WHAT KILLED IT: it moved COLOUR. Midtone R-G shifted up to -14.4 codes,
    // about six colour keys, and frame-dependently (+0.3 on another frame). Not
    // the shoulder's fault -- with the shoulder off it was still -12.2. It is
    // inherent: changing the endpoints while a NON-LINEAR exposure gamma sits
    // downstream changes channel ratios, and only a neutral is preserved by
    // `v^gamma`. And its "no blown highlights" headline belonged to the shoulder,
    // not to the endpoints: shoulder-off DRANGE blew 2.57%, WORSE than the 2.35%
    // baseline, because the blowing is the ICC reaching 255 on its own rather than
    // our clamp biting.
    //
    // Do not rebuild it as an endpoint change. If the highlight range is wanted
    // back, the honest route is a ratio-preserving roll-off (one compression factor
    // from the max channel, applied to all three) so the recovery cannot move hue.

    // ============================== DEV-CURVE ==============================
    // TO REMOVE: this block, `newCurve`, `Master.Terminator.newCurve`, the
    // `newCurve` parameter on `Master.toneSlopes`, the `|| term.newCurve` in
    // `render16`'s shoulder argument, `RollStore.newCurve`, its Settings item in
    // `main.swift`, `--new-curve` in `CLI.swift`, the second label set in
    // `Contrast.grades`, and the `newCurve` axis of the `--check-grade` sweep.
    // Then `gradationRange` goes back to a plain `(-3, 2)`.
    //
    // THE THREE CONTROLS, SEPARATED. Highlight/Shadow trim a region, Contrast sets
    // the curve, DRANGE recovers range -- and under this flag each does only its
    // own job:
    //
    //  - the SHOULDER applies to every contrast path, not just DRANGE. That is the
    //    real fix. With the hard clamp, p99 is frozen at 249.2 for Normal, Hard 1
    //    AND Hard 2 -- the top of the control does nothing, while 28 of 37 frames
    //    of the test roll sit at Hard 2 asking for it. Shouldered, p99 moves at
    //    every step (231 -> 237 -> 241 -> 244 -> 246 -> 247) and blown highlights
    //    at Normal contrast go 2.35% -> 0.00%.
    //  - CONTRAST gains a step at the top to pay for the shoulder's softness.
    //    Measured over three frames, contrast / crushed / blown:
    //      today's Hard 2   200/215/61   0.75%   2.53%
    //      shouldered +2    183/196/61   0.44%   0.08%
    //      shouldered +3    192/203/67   0.47%   0.15%   <- the new maximum
    //      shouldered +4    199/209/73   2.10%   2.33%   the ICC's toe gives way
    //    So +3 matches the old peak contrast with 17x fewer blown highlights.
    //  - DRANGE contributes ONLY the wide endpoints. Its slope is gone, so it can
    //    no longer compound with Contrast into the 12% crush that DR strong +
    //    Hard 2 produced.
    //
    // `softDamp` STAYS. It looked like a clamp workaround, but the shoulder leaves
    // the Tone Adjustment grades bit-identical: the flattening near white is the
    // ICC's OWN shoulder, not ours. Deleting it would unbalance those controls for
    // a reason that was never true.
    nonisolated(unsafe) static var newCurve = false
    /// −3…+2 as shipped; −2…+3 under DEV-CURVE. Only ever widens at the top, and
    /// saved edits top out at +2, so no stored value changes meaning.
    static var gradationRange: (Int, Int) { newCurve ? (-2, 3) : (-3, 2) }
    // =======================================================================

    // ============================== DEV-DRANGE ==============================
    /// Dynamic-range priority: keep the scene's own extremes, then buy the punch
    /// back with a SHOULDERED curve instead of a clamped one.
    ///
    /// The two halves are useless apart. Widening the endpoints alone flattens the
    /// frame; raising the slope alone just clips, because `Master.tone` is linear
    /// with a hard clamp at 0/1 -- measured, Hard 2 crushes 0.5% of an ordinary
    /// frame to pure black and Shadow Hard+ far more. Together they trade
    /// clipping for compression, which is what film's toe and shoulder do and what
    /// makes a scan of a contrasty scene hold together.
    ///
    /// Measured against the shipped path on a normal frame, output p10..p90 with
    /// the exposure solve in place (it re-solves against whichever endpoints are
    /// live, so brightness is unchanged -- median 0.524 / 0.530 / 0.540):
    ///
    ///                        contrast   crushed   blown
    ///   Normal                 0.510     0.02%    0.02%
    ///   Hard 2                 0.632     0.54%    0.18%
    ///   DR strong              0.734     0.00%    0.00%
    ///
    /// Highlights are where the range is: p0.001/p99.999 against p0.02/p99.98
    /// recovers a median 14.3% of extra span above the white point and up to
    /// 32.4% on the worst frames, against 1.3% below the black point -- film base
    /// is a hard floor, speculars and the film shoulder are not.
    ///
    /// THE SLOPE CEILING IS THE TERMINATOR'S TOE, NOT THIS CURVE, and it is why
    /// these two numbers are as small as they are. The shoulder keeps the
    /// STRETCHED value off 0 and 1, but the ICC has its own toe downstream and
    /// crushes small inputs regardless. Swept over three frames through the
    /// colleague's ICC, worst case:
    ///
    ///   slope   contrast gain   crushed   blown
    ///   off          1.00x       0.43%    2.32%
    ///   1.20         0.93x       0.23%    0.00%   too soft to be worth it
    ///   1.35         1.00x       0.28%    0.11%   <- Medium
    ///   1.45         1.05x       0.99%    0.15%   <- Strong
    ///   1.55         1.09x       3.15%    2.32%   the toe gives way
    ///   1.75         1.15x      10.57%    2.43%
    ///
    /// Through the BUILT-IN curve the same sweep crushes and blows 0.00% at every
    /// slope up to 1.75, because `paperDensity` already approaches white through a
    /// softplus and has a smooth toe. So 1.35/1.45 are set for the ICC, the path
    /// actually in use; the built-in would take much more. If more punch is wanted,
    /// Gradation composes on top of this rather than replacing it.
    ///
    /// This is a HIGHLIGHT-RECOVERY mode more than a contrast mode: the headline
    /// number is blown highlights 2.32% -> 0.11% with contrast held, not a large
    /// gain in punch. On the frames it is for -- long highlight tails, high
    /// contrast -- it does both: the candlelit frame goes contrast 48.1 -> 59.5
    /// with blown 1.43% -> 0.00%.
    /// Where the roll-off starts, as a fraction of the distance from the aim to
    /// each end. The inner half stays LINEAR, which is what keeps the aim pinned
    /// exactly and so keeps contrast independent of exposure.
    /// ASYMMETRIC, because the range at risk is asymmetric: film base is a hard
    /// floor, so the bottom tail is bounded by physics, while speculars and the
    /// film shoulder run on indefinitely at the top. Film is the same shape -- a
    /// long shoulder and a short toe.
    ///
    /// `kneeLow = 1.0` puts the lower knee at 0 so the bottom branch never fires:
    /// BLACKS KEEP THEIR FULL SLOPE. That is what stops the curve reading soft at
    /// both ends, and it lets the midtone slope go further before anything gives.
    /// Measured through the ICC at gradation +2: symmetric knees give contrast 196,
    /// top-only gives 207, and both hold blown at 0.00%.
    ///
    /// `--knee HI LO` overrides both, in the same spirit as `--xhigh`/`--xshadow`.
    nonisolated(unsafe) static var kneeHigh = 0.3
    nonisolated(unsafe) static var kneeLow = 1.0

    /// The built-in curve's log-exposure span, promoted from a hardcoded 1.4 so
    /// Settings can reach it. Its own ladder, measured on a real frame as
    /// interquartile spread / mean chroma against the ICC's 83.3 / 15.2:
    ///
    ///   1.0   87.9 / 20.6   ends lost, black 19.0 and white 239
    ///   1.2  100.7 / 22.7
    ///   1.4  111.3 / 24.0   <- default, black 12.0, white 247.7
    ///   1.6  120.7 / 25.4
    ///   1.8  129.7 / 26.6   too punchy on sight
    ///
    /// It is the one lever that moves PUNCH: it scales contrast and saturation
    /// together, so it changes the look's intensity without changing its
    /// character. Built-in terminator only -- an ICC or .cube brings its own.
    nonisolated(unsafe) static var directSpan = 1.4
    // ========================================================================

    /// Grade level with that damping applied. Both the tone warp and the side
    /// slope must use this, or they disagree about how far one press goes.
    static func gradeAmount(_ g: Grade) -> Double {
        let v = Double(g.rawValue)
        return v < 0 ? v * softDamp : v
    }

    enum ToneButton: String, CaseIterable, Identifiable {
        case standard, allSoft, allHard, shadowSoft, shadowHard, highlightSoft, highlightHard
        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: return "Standard"
            case .allSoft: return "All Soft"
            case .allHard: return "All Hard"
            case .shadowSoft: return "Shadow Soft"
            case .shadowHard: return "Shadow Hard"
            case .highlightSoft: return "Highlight Soft"
            case .highlightHard: return "Highlight Hard"
            }
        }
        /// Each preset is a SPECIFIC pair, so exactly one is ever selected.
        /// These carried nil for "leave this axis alone" once, which lit two at
        /// a time -- All Hard and Highlight Hard both have high == .hard.
        var effect: (high: Grade, shadow: Grade) {
            switch self {
            case .standard:      return (.standard, .standard)
            case .allSoft:       return (.soft, .soft)
            case .allHard:       return (.hard, .hard)
            case .highlightSoft: return (.soft, .standard)
            case .highlightHard: return (.hard, .standard)
            case .shadowSoft:    return (.standard, .soft)
            case .shadowHard:    return (.standard, .hard)
            }
        }
    }

    private static func interpDensity(_ e: Double) -> Double {
        if e <= logE[0] { return density[0] }
        if e >= logE[logE.count - 1] { return density[density.count - 1] }
        var lo = 0, hi = logE.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if logE[mid] <= e { lo = mid } else { hi = mid }
        }
        let t = (e - logE[lo]) / (logE[hi] - logE[lo])
        return density[lo] + t * (density[hi] - density[lo])
    }

    /// Paper log exposure -> encoded output, one channel. The built-in RA-4
    /// terminator, and the only consumer of the published curve left.
    @inline(__always)
    static func transfer(_ e: Double, channel c: Int) -> Double {
        srgbEncode(pow(10.0, dMin - paperDensity(e, channel: c)))
    }

    static func paperDensity(_ eWarped: Double, channel: Int) -> Double {
        // The crossover is a property of the PAPER, so it is a function of where
        // the tone LANDED and nothing else. Applied to the pre-paper value it
        // couples to the gradation slope and a contrast press visibly moves the
        // hue -- measured 89/110/117 degrees across highlight soft2/std/hard2.
        let d = eWarped - midGreyLogE
        let hiSide = d < 0
        let e = midGreyLogE + d * (1 + (hiSide ? crossoverHigh : crossoverShadow)
                                       * channelTilt(channel, highlight: hiSide))
        let last = density[density.count - 1]
        var shape = (interpDensity(e) - dMin) / (last - dMin)
        shape = min(max(shape, 0), 1)
        let shared = dMin + shape * (last - dMin)
        let peak = channel == 0 ? dMax.0 : (channel == 1 ? dMax.1 : dMax.2)
        let dens = shared + pow(shape, shoulderN) * (peak - last)
        // SOFT floor, not max(). A hard clamp pinned every highlight past 248 to
        // exactly 248 -- a flat region with real content in it and zero
        // derivative, so the Highlight control had nothing to act on: highlights
        // moved 0.3 codes against the Kodak LUT's 1.6 while midtones moved 2.1
        // either way, which is why it read as a midtone control.
        let floor = dMin + whiteFloor
        let t = (dens - floor) / whiteSoftness
        // softplus: always above the floor, but with a live slope through it.
        return floor + whiteSoftness * (t > 20 ? t : log(1 + exp(t)))
    }

    /// Width of the soft approach to paper white, in density.
    static let whiteSoftness = 0.015

    /// Paper white reads 248, never 255. Dmin maps to reflectance 1.0, so any
    /// control pushed far enough could land on pure white -- the crossover gamma
    /// managed it alone on 0.336% of pixels once slopes reached 1.35. Flooring
    /// the DENSITY is the one place that cannot be bypassed; an earlier attempt
    /// clamped the exposure and silently disabled the gradation controls, whose
    /// slope legitimately extends past the shoulder.
    static let whiteFloor: Double = -log10(srgbDecode(248.0 / 255.0))

    @inline(__always)
    static func srgbDecode(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// Float overload for paths that carry Float end to end. Same curve; the
    /// ICC transform had its own private copy of these four constants.
    @inline(__always)
    static func srgbEncode(_ v: Float) -> Float {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
    }

    static func srgbEncode(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }

    // DEV-AUTOEXP
    /// The print aim: output luminance a frame's LATD is placed on. 18% is the
    /// standard aim, and it is a LIFT on both test rolls, not a darkening --
    /// measured before auto exposure existed, median output luminance was -0.33 EV
    /// on the 37-frame roll and -1.10 EV on the 12-frame one, every frame of the
    /// latter below 18%. Which is exactly the "frames are too dark" report.
    ///
    /// Measured after: the frame interior lands at 0.236 / 0.251 / 0.266 through
    /// the ICC / .cube / RA-4 respectively, i.e. +0.4 EV and agreeing to 0.17 EV
    /// across all three. Above the aim because the median pixel is not neutral,
    /// and `aimValue` solves for a neutral.
    static let printAim = 0.18

    // `autoGammaMin` = 0.70 / `autoGammaMax` = 1.8 STOOD HERE AND ARE GONE.
    // The min was described as "the ONLY tuned number in auto exposure", touching
    // "exactly ONE frame of the 49". That was measured through the ICC. On the
    // built-in curve below -- the DEFAULT terminator -- it bound on 43 of 49 and
    // was the whole of the -1.5 EV "previews are too dark". Auto exposure is now
    // unlimited; see `Master.autoGamma` for why lifting is the correct behaviour
    // and for the two replacements that measured worse.

    /// Rec.709 luma, for the black-and-white collapse. Mixed in LINEAR light,
    /// so the result carries the colour render's luminance exactly.
    static let lumaW = (0.2126, 0.7152, 0.0722)

    /// DEV-MONO — render as black and white.
    ///
    /// A roll property, mirrored here from the store the same way `printLUT` and
    /// `outputICC` are, because the terminator block is the one place all three
    /// print paths pass through.
    ///
    /// It has to act AFTER the terminator. A neutral master does not print
    /// neutral: both terminators are designed to tone one, measured at up to
    /// 21.7 code values of channel spread through the curve below and 20 through
    /// the colleague's ICC. Zeroing `crossoverHigh`/`crossoverShadow` would fix
    /// only this file's curve and could not de-tint an ICC or a .cube at all.
    ///
    /// TO REMOVE: grep DEV-MONO. See the list on `RollStore.monochrome`.
    nonisolated(unsafe) static var monochrome = false

    /// The two alternative terminators, both in the same position as the paper
    /// curve: they consume the stretched master and produce sRGB. Neither can
    /// replace the render, because neither inverts.
    nonisolated(unsafe) static var printLUT: PrintLUT?
    nonisolated(unsafe) static var outputICC: ICCOnly.Transform?

    /// What is actually terminating the pipeline, for the readouts. Same order
    /// `Master.render16` branches in, so the label cannot disagree with the
    /// pixels -- it read them the other way round once and named the ICC while
    /// the cube was rendering.
    static var modelName: String {
        outputICC?.name ?? printLUT?.name ?? "Horizon RA-4 (built-in)"
    }
}
