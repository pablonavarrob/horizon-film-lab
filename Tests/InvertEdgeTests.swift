import Foundation

final class InvertEdgeTests {
    private let width = 1024
    private let height = 256
    private let inset = 64

    /// Uniform side borders around textured picture data. A channel above the
    /// gate ceiling has no samples left when detectEdges measures its base.
    private func density(border: [Float], picture: [Float]? = nil) -> [[Float]] {
        let picture = picture ?? border.map { $0 + 0.4 }
        var planes = [[Float]](repeating: [Float](repeating: 0, count: width * height),
                               count: 3)
        for y in 0..<height {
            for x in 0..<width {
                let atBorder = x < inset || x >= width - inset
                for c in 0..<3 {
                    planes[c][y * width + x] = atBorder ? border[c]
                        : picture[c] + Float((x + y) % 2) * 0.4
                }
            }
        }
        return planes
    }

    func testBorderWithEmptyGreenOrBlueSamples() {
        let high = Float(Invert.gateCeiling) + 0.2
        let borders: [[Float]] = [[0.3, high, 0.5], [0.3, 0.4, high], [0.3, high, high]]
        for border in borders {
            let result = Invert.detectEdges(density(border: border), w: width, h: height)
            precondition(result == Invert.Border(left: inset, right: inset), "\(border): \(result)")
        }
    }

    func testOrdinaryBorderRemainsDetected() {
        let result = Invert.detectEdges(density(border: [0.3, 0.4, 0.5]),
                                        w: width, h: height)
        precondition(result == Invert.Border(left: inset, right: inset), "\(result)")
    }

    func testOpaqueBorderWithAllSamplesFiltered() {
        let high = Float(Invert.gateCeiling) + 0.2
        let result = Invert.detectEdges(
            density(border: [high, high, high], picture: [0.7, 0.8, 0.9]),
            w: width, h: height)
        precondition(result == Invert.Border(left: inset, right: inset), "\(result)")
    }

    func testTIFFImportWithEmptyGreenBorderSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizon-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let d = density(border: [0.3, Float(Invert.gateCeiling) + 0.2, 0.5])
        var rgb = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                rgb[i * 3 + c] = UInt16((pow(10.0, -Double(d[c][i])) * 65535).rounded())
            }
        }
        // writeMaster writes these 16-bit values verbatim, so the fixture holds
        // raw linear counts, as an imported capture would.
        try Invert.writeMaster(rgb, w: width, h: height,
                               to: root.appendingPathComponent("capture.tiff"))
        let output = root.appendingPathComponent("cache", isDirectory: true)
        try Invert.run(dir: root, layout: .rgb1, perFrameBase: true, out: output)

        let master = try Invert.planes(output.appendingPathComponent("capture.ntg.tif"))
        precondition(master.w == width && master.h == height)
        precondition(Invert.loadSession(beside: output)?.frameBorders["capture"]
                     == Invert.Border(left: inset, right: inset))
    }
}

@main
struct InvertEdgeTestRunner {
    static func main() throws {
        let tests = InvertEdgeTests()
        tests.testBorderWithEmptyGreenOrBlueSamples()
        tests.testOrdinaryBorderRemainsDetected()
        tests.testOpaqueBorderWithAllSamplesFiltered()
        try tests.testTIFFImportWithEmptyGreenBorderSamples()
        print("4 edge/import regression tests passed")
    }
}
