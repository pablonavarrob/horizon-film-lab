import Foundation

/// Experimental roll-level carrier estimate. Samples are collected from the
/// density planes already decoded for inversion; no second source read or
/// intermediate image is needed. Only opaque, repeated edge bands qualify.
enum CarrierMask {
    struct Sample {
        let w: Int
        let h: Int
        let gw: Int
        let gh: Int
        let dark: [Float] // minimum RGB density: opaque only if all channels are

        func opaque(_ side: Int, _ line: Int) -> Bool {
            let n = side < 2 ? gh : gw
            var hits = 0, total = 0
            for i in 0..<16 {
                let along = max(0, min(n - 1, (i * 8 + 4) * n / 128))
                let x = side < 2 ? (side == 0 ? line : gw - 1 - line) : along
                let y = side >= 2 ? (side == 2 ? line : gh - 1 - line) : along
                if dark[y * gw + x] >= Float(Invert.gateCeiling) { hits += 1 }
                total += 1
            }
            return hits >= 14 && total == 16
        }
    }

    static func sample(_ d: [[Float]], w: Int, h: Int) -> Sample {
        let gw = min(256, w), gh = min(256, h)
        var dark = [Float](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            let sy = min(h - 1, (2 * y + 1) * h / (2 * gh))
            for x in 0..<gw {
                let sx = min(w - 1, (2 * x + 1) * w / (2 * gw))
                let i = sy * w + sx
                dark[y * gw + x] = min(d[0][i], min(d[1][i], d[2][i]))
            }
        }
        return Sample(w: w, h: h, gw: gw, gh: gh, dark: dark)
    }

    /// Supplemental insets only for sides the normal detector left at zero.
    /// Three same-sized scans and agreement across at least 80% are required.
    static func borders(samples: [String: Sample],
                        detected: [String: Invert.Border]) -> [String: Invert.Border] {
        var result: [String: Invert.Border] = [:]
        let groups = Dictionary(grouping: samples.keys) {
            let s = samples[$0]!
            return "\(s.w)x\(s.h)"
        }
        for names in groups.values where names.count >= 3 {
            guard let first = names.first.flatMap({ samples[$0] }) else { continue }
            var proposed = [Int](repeating: 0, count: 4)
            for side in 0..<4 {
                let axis = side < 2 ? first.gw : first.gh
                let cap = min(axis / 3, Int(Double(axis) * 0.35))
                var run = 0
                for line in 0..<cap {
                    let agrees = names.filter { samples[$0]!.opaque(side, line) }.count
                    if agrees * 5 < names.count * 4 { break }
                    run = line + 1
                }
                // A two-cell margin protects statistics against resampling the
                // transition. It cannot exceed 35% of the original capture.
                proposed[side] = run >= 2 ? min(cap, run + 2) : 0
            }
            for name in names {
                guard let s = samples[name] else { continue }
                let ordinary = detected[name] ?? Invert.Border()
                var b = Invert.Border()
                for side in 0..<4 where proposed[side] > 0 {
                    let axis = side < 2 ? s.gw : s.gh
                    let line = proposed[side]
                    let outside = (0..<max(1, line - 2)).filter { s.opaque(side, $0) }.count
                    let valid = outside * 5 >= max(1, line - 2) * 4
                        && line + 2 < axis && !s.opaque(side, line + 2)
                    guard valid else { continue }
                    let pixels = line * (side < 2 ? s.w : s.h) / axis
                    switch side {
                    case 0 where ordinary.left == 0: b.left = pixels
                    case 1 where ordinary.right == 0: b.right = pixels
                    case 2 where ordinary.top == 0: b.top = pixels
                    case 3 where ordinary.bottom == 0: b.bottom = pixels
                    default: break
                    }
                }
                if !b.isEmpty { result[name] = b }
            }
        }
        return result
    }
}
