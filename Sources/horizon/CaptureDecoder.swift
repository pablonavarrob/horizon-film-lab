import CoreImage
import Foundation

/// Both file paths end at the same normalized, linear RGB planes consumed by
/// Invert. Camera RAW is decoded in memory; no intermediate image is written.
enum CaptureDecoder {
    static let bitmapExtensions: Set<String> = ["tif", "tiff", "png"]
    static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "dng", "erf", "iiq", "mos", "nef",
        "nrw", "orf", "pef", "raf", "raw", "rwl", "rw2", "srw"
    ]
    static let supportedExtensions = bitmapExtensions.union(rawExtensions)

    static func isRAW(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Apple's RAW pipeline must still demosaic, map camera channels to RGB, and
    /// use its camera white point. All optional photographic enhancement is zero.
    /// The output colour space is linear; no print or display curve is applied.
    private static func rawFilter(_ url: URL) throws -> CIRAWFilter {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw Err("Apple RAW decoder cannot open \(url.lastPathComponent)")
        }
        // Keep sensor pixel orientation, as ImageIO does for TIFF sample data.
        filter.orientation = .up
        filter.isDraftModeEnabled = false
        filter.scaleFactor = 1
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 1
        filter.isGamutMappingEnabled = false
        filter.isLensCorrectionEnabled = false
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.contrastAmount = 0
        filter.detailAmount = 0
        filter.moireReductionAmount = 0
        filter.localToneMapAmount = 0
        filter.extendedDynamicRangeAmount = 0
        filter.linearSpaceFilter = nil
        // macOS 16 added this optional treatment. Keep the macOS 14 build
        // target while disabling it at runtime on systems that expose it.
        let recoverySetter = NSSelectorFromString("setHighlightRecoveryEnabled:")
        if filter.responds(to: recoverySetter) {
            filter.setValue(false, forKey: "highlightRecoveryEnabled")
        }
        return filter
    }

    static func imageSize(_ url: URL) -> (w: Int, h: Int)? {
        guard let filter = try? rawFilter(url) else { return nil }
        return (Int(filter.nativeSize.width), Int(filter.nativeSize.height))
    }

    static func planes(_ url: URL) throws -> (p: [[Float]], w: Int, h: Int) {
        let filter = try rawFilter(url)
        guard let output = filter.outputImage else {
            throw Err("Apple RAW decoder could not demosaic \(url.lastPathComponent)")
        }
        let bounds = output.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0, w <= Int.max / h / 4 else {
            throw Err("invalid RAW dimensions for \(url.lastPathComponent)")
        }
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw Err("linear RGB colour space unavailable")
        }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .outputColorSpace: linear])
        var rgba = [Float](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(output, toBitmap: bytes.baseAddress!, rowBytes: w * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        var rgb = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
        for i in 0..<(w * h) {
            let at = i * 4
            for c in 0..<3 {
                let v = rgba[at + c]
                rgb[c][i] = v.isFinite ? max(0, v) : 0
            }
        }
        return (rgb, w, h)
    }
}
