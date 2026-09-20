import Accelerate
import Foundation

/// A 3D print-emulation LUT in .cube form, applied to the Cineon master.
///
/// This is the industry path a colourist uses: export Cineon log, then grade
/// through a film print LUT. Our master IS Cineon log -- code/1023, which is
/// exactly the "floating point 0.0-1.0" these LUTs declare as their input -- so
/// it drops in with no conversion. The Kodak 2383 files ship in Resources/luts.
///
/// It TERMINATES the pipeline, in the same position as the ICC and the built-in
/// RA-4 curve: the per-frame levels stretch runs first and this supplies the
/// transfer. All three terminators consume the same stretched master, which is
/// what makes them directly comparable.
struct PrintLUT: Sendable {
    let size: Int
    /// size^3 * 3 floats, red varying fastest -- the .cube convention.
    let data: [Float]
    let name: String
    let domainMin: Float, domainMax: Float

    // MARK: - Parse

    static func load(_ url: URL) throws -> PrintLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        var grid = 0
        var lo: Float = 0, hi: Float = 1
        var vals: [Float] = []
        vals.reserveCapacity(35937 * 3)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // .whitespacesAndNewlines, not .whitespaces: a CRLF file leaves \r on
            // every line, which .whitespaces does not strip, so "LUT_3D_SIZE\r"
            // matched nothing and every such .cube was rejected as malformed.
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            switch f[0].uppercased() {
            case "LUT_3D_SIZE":
                grid = f.count > 1 ? Int(f[1]) ?? 0 : 0
            case "LUT_3D_INPUT_RANGE", "DOMAIN_MIN", "DOMAIN_MAX":
                // DOMAIN_MIN/MAX are one triplet each; INPUT_RANGE is lo hi.
                if f[0].uppercased() == "LUT_3D_INPUT_RANGE", f.count > 2 {
                    lo = Float(f[1]) ?? 0; hi = Float(f[2]) ?? 1
                } else if f[0].uppercased() == "DOMAIN_MIN", f.count > 1 {
                    lo = Float(f[1]) ?? 0
                } else if f.count > 1 {
                    hi = Float(f[1]) ?? 1
                }
            case "TITLE", "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                if f[0].uppercased() == "LUT_1D_SIZE" {
                    throw Err("\(url.lastPathComponent) is a 1D LUT; a 3D print LUT is expected")
                }
            default:
                guard f.count >= 3, let r = Float(f[0]), let g = Float(f[1]), let b = Float(f[2])
                else { continue }
                vals.append(r); vals.append(g); vals.append(b)
            }
        }
        guard grid > 1 else { throw Err("\(url.lastPathComponent): no LUT_3D_SIZE") }
        guard vals.count == grid * grid * grid * 3 else {
            throw Err("\(url.lastPathComponent): expected \(grid * grid * grid) entries, got \(vals.count / 3)")
        }
        guard hi > lo else { throw Err("\(url.lastPathComponent): bad input range") }
        return PrintLUT(size: grid, data: vals,
                        name: url.deletingPathExtension().lastPathComponent,
                        domainMin: lo, domainMax: hi)
    }

    // MARK: - Apply

    /// Trilinear interpolation. One sample, three normalised log inputs.
    @inline(__always)
    func sample(_ rIn: Float, _ gIn: Float, _ bIn: Float) -> (Float, Float, Float) {
        let n = size - 1, scale = Float(n) / (domainMax - domainMin)
        func axis(_ v: Float) -> (Int, Int, Float) {
            let t = min(max((v - domainMin) * scale, 0), Float(n))
            let i = min(Int(t), n - 1)
            return (i, min(i + 1, n), t - Float(i))
        }
        let (r0, r1, fr) = axis(rIn), (g0, g1, fg) = axis(gIn), (b0, b1, fb) = axis(bIn)
        // .cube order: red fastest, then green, then blue.
        @inline(__always) func at(_ ri: Int, _ gi: Int, _ bi: Int) -> (Float, Float, Float) {
            let o = ((bi * size + gi) * size + ri) * 3
            return (data[o], data[o + 1], data[o + 2])
        }
        @inline(__always) func mix(_ a: (Float, Float, Float), _ b: (Float, Float, Float),
                                   _ t: Float) -> (Float, Float, Float) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        let c00 = mix(at(r0, g0, b0), at(r1, g0, b0), fr)
        let c10 = mix(at(r0, g1, b0), at(r1, g1, b0), fr)
        let c01 = mix(at(r0, g0, b1), at(r1, g0, b1), fr)
        let c11 = mix(at(r0, g1, b1), at(r1, g1, b1), fr)
        return mix(mix(c00, c10, fg), mix(c01, c11, fg), fb)
    }

    /// These LUTs output Rec.709 at gamma 2.4 (stated in the file header), not
    /// sRGB. Showing 2.4-encoded data as sRGB lifts it, because v^2.2 > v^2.4 --
    /// washed shadows. Linearise at 2.4 and re-encode for the actual display.
    @inline(__always)
    static func toSRGB(_ v: Float) -> Float {
        // The .cube outputs are gamma 2.4 encoded, so decode to linear before
        // re-encoding to sRGB. Pure 2.4, not the sRGB curve -- that is what the
        // Rec.709 LUTs in Resources are authored against.
        // Double, not the Float overload: powf in single precision differs by
        // one code value here, and this path was bit-exact before. The Float
        // overload exists for the ICC transform, which is Float end to end.
        let lin = powf(min(max(v, 0), 1), 2.4)
        return Float(Paper.srgbEncode(Double(lin)))
    }

    /// The built-in stocks. Checks the app bundle first, then the source tree
    /// beside the executable -- running the raw SPM binary has no bundle
    /// resources, which is the same trap the logo fell into.
    static func bundled() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("luts")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        dirs.append(exe.appendingPathComponent("luts"))
        // .build/release/horizon -> ../../Resources/luts
        dirs.append(exe.deletingLastPathComponent().deletingLastPathComponent()
                       .appendingPathComponent("Resources/luts"))
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                       .appendingPathComponent("Resources/luts"))
        for d in dirs {
            guard let f = try? FileManager.default.contentsOfDirectory(
                at: d, includingPropertiesForKeys: nil) else { continue }
            let cubes = f.filter { $0.pathExtension.lowercased() == "cube" }
            if !cubes.isEmpty { return cubes.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        }
        return []
    }
}
