import Foundation

/// Fits a shared printer-light correction to recurring near-neutral evidence.
/// All candidate changes are upstream of the print transform. Its own neutral
/// colour is the reference, so a warm paper does not get neutralised away.
enum RollColourCorrection {
    struct Input {
        let master: Master
        let edit: Edit
    }
    struct Result {
        let cyan: Double, magenta: Double, yellow: Double
        let frames: Int, fraction: Double
    }
    private struct Sample {
        let v: SIMD3<Double>
        let frame: Int
    }

    static func estimate(_ inputs: [Input], term: Master.Terminator,
                         cancelled: () -> Bool = { false }) -> Result? {
        guard !term.mono, !inputs.isEmpty else { return nil }
        let bins = 31, limit = 0.24
        func bin(_ x: Double) -> Int { min(bins - 1, max(0, Int((x + limit) / (2 * limit) * Double(bins)))) }
        var candidates: [Sample] = []
        var total = 0
        var histogram = [Double](repeating: 0, count: bins * bins)
        for (frame, input) in inputs.enumerated() {
            if cancelled() { return nil }
            let m = input.master
            var edit = input.edit
            edit.autoCyan = 0; edit.autoMagenta = 0; edit.autoYellow = 0
            let gamma = m.autoGamma(term, edit), aim = Master.aimTarget(term, edit)
            let slopes = Master.toneSlopes(edit, newCurve: term.newCurve)
            let off = Master.cmyOffsets(edit)
            let offsets = [off.0, off.1, off.2]
            let box = (m.frameMask ?? Invert.Border()).inner(w: m.width, h: m.height)
            let strideX = max(1, (box.x1 - box.x0) / 48)
            let strideY = max(1, (box.y1 - box.y0) / 32)
            var local: [Sample] = []
            for y in stride(from: box.y0 + 2, to: box.y1 - 2, by: strideY) {
                for x in stride(from: box.x0 + 2, to: box.x1 - 2, by: strideX) {
                    let index = y * m.width + x
                    var v = SIMD3<Double>()
                    for c in 0..<3 {
                        v[c] = Master.curveValue(Double(m.planes[c][index]) / 65535,
                            lo: m.ends.lo, hi: m.ends.hi, gamma: gamma, aim: aim,
                            slopes: slopes, offset: offsets[c],
                            shoulder: term.newCurve && term.clampsHard,
                            kneeHigh: term.kneeHigh, kneeLow: term.kneeLow)
                    }
                    total += 1
                    let mean = (v.x + v.y + v.z) / 3
                    // Avoid clipped endpoints. Selection is before the print
                    // look and broad enough to retain materially cast neutrals.
                    guard mean > 0.16, mean < 0.84,
                          min(v.x, min(v.y, v.z)) > 0.025,
                          max(v.x, max(v.y, v.z)) < 0.975,
                          abs(v.x - v.y) < limit, abs(v.z - v.y) < limit else { continue }
                    local.append(Sample(v: v, frame: frame))
                }
            }
            guard local.count >= 24 else { continue }
            let weight = 1 / Double(local.count)
            for sample in local {
                histogram[bin(sample.v.x - sample.v.y) * bins + bin(sample.v.z - sample.v.y)] += weight
            }
            candidates += local
        }
        guard candidates.count >= 64, total > 0 else { return nil }

        // A recurrent chroma mode, with equal total vote per photograph.
        // Smooth adjoining bins so grain does not move the winning population.
        var best = -Double.infinity, centre = SIMD2<Double>()
        for r in 1..<(bins - 1) {
            for b in 1..<(bins - 1) {
                var score = 0.0
                for dr in -1...1 { for db in -1...1 { score += histogram[(r + dr) * bins + b + db] } }
                let xy = SIMD2((Double(r) + 0.5) / Double(bins) * 2 * limit - limit,
                               (Double(b) + 0.5) / Double(bins) * 2 * limit - limit)
                // Prefer the less intrusive solution only when evidence ties.
                score -= (xy.x * xy.x + xy.y * xy.y) * 1e-6
                if score > best { best = score; centre = xy }
            }
        }
        let selected = candidates.filter {
            abs(($0.v.x - $0.v.y) - centre.x) < 0.028 &&
            abs(($0.v.z - $0.v.y) - centre.y) < 0.028
        }
        let groups = Dictionary(grouping: selected, by: \.frame).filter { $0.value.count >= 24 }
        let required = inputs.count == 1 ? 1 : max(2, Int(ceil(Double(inputs.count) * 0.35)))
        guard groups.count >= required, selected.count >= 64,
              Double(selected.count) / Double(total) >= 0.015 else { return nil }

        func output(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let rgb = Master.outLinear((v.x, v.y, v.z), icc: term.icc, lut: term.lut,
                span: term.span, crossoverHigh: term.crossoverHigh,
                crossoverShadow: term.crossoverShadow)
            return SIMD3(Paper.srgbEncode(rgb.0), Paper.srgbEncode(rgb.1), Paper.srgbEncode(rgb.2))
        }
        let reference = groups.keys.sorted().map { key in
            (groups[key] ?? []).map { sample -> (SIMD3<Double>, SIMD3<Double>) in
                let mean = (sample.v.x + sample.v.y + sample.v.z) / 3
                return (sample.v, output(SIMD3(repeating: mean)))
            }
        }
        // Two independent colour axes with zero common density offset.
        func residual(_ keys: SIMD2<Double>) -> SIMD2<Double> {
            let offset = SIMD3(keys.x, -keys.x - keys.y, keys.y) * Master.cmyUnit
            var result = SIMD2<Double>()
            for frame in reference {
                var residuals: [SIMD2<Double>] = []
                for (input, target) in frame {
                    let value = input - offset
                    guard min(value.x, min(value.y, value.z)) > 0,
                          max(value.x, max(value.y, value.z)) < 1 else { continue }
                    let o = output(value) - target
                    residuals.append(SIMD2(o.x - o.y, o.z - o.y))
                }
                guard !residuals.isEmpty else { continue }
                // Median per photograph prevents a few scene-coloured samples
                // from setting the correction; frames then carry equal weight.
                let a = residuals.map(\.x).sorted(), b = residuals.map(\.y).sorted()
                result += SIMD2(a[a.count / 2], b[b.count / 2])
            }
            return result / Double(reference.count)
        }
        var keys = SIMD2<Double>()
        let initial = residual(keys)
        var previous = initial.x * initial.x + initial.y * initial.y
        for _ in 0..<7 {
            if cancelled() { return nil }
            let r = residual(keys)
            if max(abs(r.x), abs(r.y)) < 0.0005 { break }
            let step = 0.25
            let a = (residual(keys + SIMD2(step, 0)) - r) / step
            let b = (residual(keys + SIMD2(0, step)) - r) / step
            let determinant = a.x * b.y - b.x * a.y
            guard abs(determinant) > 1e-10 else { break }
            let delta = SIMD2((b.y * r.x - b.x * r.y) / determinant,
                              (-a.y * r.x + a.x * r.y) / determinant)
            var accepted = false
            for scale in [1.0, 0.5, 0.25, 0.125] {
                let next = keys - delta * scale
                guard max(abs(next.x), max(abs(next.y), abs(next.x + next.y))) <= 24 else { continue }
                let nr = residual(next), score = nr.x * nr.x + nr.y * nr.y
                if score < previous {
                    keys = next; previous = score; accepted = true; break
                }
            }
            if !accepted { break }
        }
        if previous > 0.0001 && previous > (initial.x * initial.x + initial.y * initial.y) * 0.8 { return nil }
        func rounded(_ v: Double) -> Double { abs(v) < 0.1 ? 0 : (v * 10).rounded() / 10 }
        return Result(cyan: rounded(keys.x), magenta: rounded(-keys.x - keys.y),
                      yellow: rounded(keys.y), frames: groups.count,
                      fraction: Double(selected.count) / Double(total))
    }
}
