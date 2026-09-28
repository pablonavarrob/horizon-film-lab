import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images for inspecting border evidence. All geometry here is diagnostic: the
/// ordinary detector and Beta consensus are called by Invert, never changed.
enum CarrierDiagnostics {
    struct Report {
        let preview: URL
        let files: [URL]
        let summary: String
    }

    struct Frame {
        let name: String
        let sample: CarrierMask.Sample
        let ordinary: Invert.Border
        let candidate: Invert.Border
        let applied: Invert.Border
    }

    private static let normal = CGColor(red: 0.15, green: 0.88, blue: 0.97, alpha: 0.95)
    private static let candidate = CGColor(red: 1.0, green: 0.64, blue: 0.17, alpha: 0.95)
    private static let applied = CGColor(red: 0.40, green: 0.95, blue: 0.54, alpha: 0.95)
    private static let white = CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
    private static let muted = CGColor(red: 0.70, green: 0.75, blue: 0.80, alpha: 1)

    private static func text(_ value: String, x: CGFloat, y: CGFloat,
                             size: CGFloat, colour: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: value, attributes: attributes))
        context.saveGState()
        context.translateBy(x: x, y: y + size)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Err("cannot create border diagnostic image")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.065, green: 0.077, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private static func image(w: Int, h: Int, pixels: [UInt8]) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue:
                                      CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw Err("cannot draw border diagnostic samples")
        }
        return image
    }

    /// White means high negative density. This is the mean minimum RGB density,
    /// not an average photograph or a rendered positive.
    private static func densityImage(_ samples: [CarrierMask.Sample]) throws -> CGImage {
        let first = samples[0]
        let n = first.gw * first.gh
        var pixels = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            var sum: Float = 0
            for sample in samples { sum += sample.dark[i] }
            let level = max(0, min(1, sum / Float(samples.count) / 3.2))
            let code = UInt8((25 + level * 225).rounded())
            let at = i * 4
            pixels[at] = code; pixels[at + 1] = code
            pixels[at + 2] = code; pixels[at + 3] = 255
        }
        return try image(w: first.gw, h: first.gh, pixels: pixels)
    }

    /// Fraction of grouped frames at each position whose minimum channel exceeds
    /// the same opaque-density threshold that Beta's edge test uses.
    private static func agreementImage(_ samples: [CarrierMask.Sample]) throws -> CGImage {
        let first = samples[0]
        let n = first.gw * first.gh
        var pixels = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            let count = samples.reduce(0) {
                $0 + ($1.dark[i] >= Float(Invert.gateCeiling) ? 1 : 0)
            }
            let agreement = Float(count) / Float(samples.count)
            let at = i * 4
            pixels[at] = UInt8((27 + agreement * 220).rounded())
            pixels[at + 1] = UInt8((34 + agreement * 76).rounded())
            pixels[at + 2] = UInt8((43 + agreement * 25).rounded())
            pixels[at + 3] = 255
        }
        return try image(w: first.gw, h: first.gh, pixels: pixels)
    }

    private static func draw(_ image: CGImage, in rect: CGRect,
                             on context: CGContext) {
        // Keep source row zero at the top while the report uses top-left layout.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func overlay(_ border: Invert.Border, source: CarrierMask.Sample,
                                rect: CGRect, colour: CGColor, on context: CGContext) {
        guard !border.isEmpty else { return }
        let scaleX = rect.width / CGFloat(source.w)
        let scaleY = rect.height / CGFloat(source.h)
        let inside = CGRect(x: rect.minX + CGFloat(border.left) * scaleX,
                            y: rect.minY + CGFloat(border.top) * scaleY,
                            width: max(0, rect.width - CGFloat(border.left + border.right) * scaleX),
                            height: max(0, rect.height - CGFloat(border.top + border.bottom) * scaleY))
        guard inside.width > 1, inside.height > 1 else { return }
        context.setFillColor(colour.copy(alpha: 0.14)!)
        context.fill(CGRect(x: rect.minX, y: rect.minY,
                            width: rect.width, height: inside.minY - rect.minY))
        context.fill(CGRect(x: rect.minX, y: inside.maxY,
                            width: rect.width, height: rect.maxY - inside.maxY))
        context.fill(CGRect(x: rect.minX, y: inside.minY,
                            width: inside.minX - rect.minX, height: inside.height))
        context.fill(CGRect(x: inside.maxX, y: inside.minY,
                            width: rect.maxX - inside.maxX, height: inside.height))
        context.setStrokeColor(colour)
        context.setLineWidth(2.5)
        context.stroke(inside)
    }

    private static func dimensions(_ sample: CarrierMask.Sample,
                                   maxWidth: Int = 1050, maxHeight: Int = 720)
        -> (w: Int, h: Int) {
        let scale = min(Double(maxWidth) / Double(sample.w),
                        Double(maxHeight) / Double(sample.h))
        return (max(1, Int((Double(sample.w) * scale).rounded())),
                max(1, Int((Double(sample.h) * scale).rounded())))
    }

    private static func write(_ context: CGContext, to url: URL) throws {
        guard let image = context.makeImage() else { throw Err("cannot finish border diagnostic") }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).writing.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Err("cannot write border diagnostic \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), rename(temporary.path, url.path) == 0 else {
            throw Err("cannot finish border diagnostic \(url.lastPathComponent)")
        }
    }

    static func overview(names: [String], samples: [String: CarrierMask.Sample],
                         ordinary: [String: Invert.Border],
                         candidates: [String: Invert.Border],
                         applicability: String, to url: URL) throws {
        guard let firstName = names.first, let first = samples[firstName] else {
            throw Err("no carrier samples for overview")
        }
        let pooled = names.compactMap { samples[$0] }
        let d = dimensions(first, maxWidth: 550, maxHeight: 620)
        let margin: CGFloat = 28, top: CGFloat = 116, gap: CGFloat = 26
        let width = max(1120, Int(margin * 2 + CGFloat(d.w * 2) + gap))
        let height = Int(top + CGFloat(d.h) + 128)
        let context = try context(width: width, height: height)
        text("ROLL BORDER DIAGNOSTIC", x: margin, y: 20, size: 20,
             colour: white, in: context)
        text("\(names.count) same-size grouped frame(s)  ·  \(first.w) × \(first.h) pixels", x: margin,
             y: 49, size: 14, colour: muted, in: context)
        text(applicability, x: margin, y: 70, size: 14, colour: candidate, in: context)
        let panelsX = (CGFloat(width) - CGFloat(d.w * 2) - gap) / 2
        let left = CGRect(x: panelsX, y: top,
                          width: CGFloat(d.w), height: CGFloat(d.h))
        let right = CGRect(x: panelsX + CGFloat(d.w) + gap, y: top,
                           width: CGFloat(d.w), height: CGFloat(d.h))
        draw(try densityImage(pooled), in: left, on: context)
        draw(try agreementImage(pooled), in: right, on: context)
        let normalGate = Invert.Border.gate(of: Dictionary(uniqueKeysWithValues:
            names.map { ($0, ordinary[$0] ?? Invert.Border()) }))
        let candidateGate = Invert.Border.gate(of: Dictionary(uniqueKeysWithValues:
            names.map { ($0, candidates[$0] ?? Invert.Border()) }))
        for rect in [left, right] {
            overlay(normalGate, source: first, rect: rect, colour: normal, on: context)
            overlay(candidateGate, source: first, rect: rect, colour: candidate, on: context)
        }
        text("Mean minimum-channel negative density", x: left.minX, y: 93,
             size: 13, colour: white, in: context)
        text("Opaque agreement across frames", x: right.minX, y: 93,
             size: 13, colour: white, in: context)
        text("Cyan: ordinary gate for this size group   Orange: fresh Beta candidate union",
             x: margin, y: top + CGFloat(d.h) + 19, size: 13, colour: muted, in: context)
        let evidence = names.count < 3
            ? "Fewer than three matching frames: Beta has no roll consensus."
            : candidateGate.isEmpty
                ? "No additional persistent opaque carrier was accepted by Beta."
                : "Tinted exterior shows measurement exclusions proposed by the Beta analysis."
        text(evidence, x: margin, y: top + CGFloat(d.h) + 43,
             size: 13, colour: white, in: context)
        text("Agreement heatmap: brighter orange means more frames exceed the opaque-density threshold.",
             x: margin, y: top + CGFloat(d.h) + 67, size: 12, colour: muted, in: context)
        text("This report changes no images. Beta candidates affect statistics only; normal borders may crop exports.",
             x: margin, y: top + CGFloat(d.h) + 88, size: 12, colour: muted, in: context)
        try write(context, to: url)
    }

    static func frame(_ frame: Frame, applicability: String, to url: URL) throws {
        let d = dimensions(frame.sample)
        let margin: CGFloat = 30, top: CGFloat = 113
        let width = max(880, Int(CGFloat(d.w) + margin * 2))
        let height = Int(top + CGFloat(d.h) + 117)
        let context = try context(width: width, height: height)
        text(frame.name, x: margin, y: 19, size: 21, colour: white, in: context)
        text(applicability, x: margin, y: 49, size: 13, colour: candidate, in: context)
        text("Minimum-channel negative density · white = dense/opaque", x: margin,
             y: 76, size: 13, colour: muted, in: context)
        let rect = CGRect(x: (CGFloat(width) - CGFloat(d.w)) / 2,
                          y: top, width: CGFloat(d.w), height: CGFloat(d.h))
        draw(try densityImage([frame.sample]), in: rect, on: context)
        overlay(frame.ordinary, source: frame.sample, rect: rect,
                colour: normal, on: context)
        overlay(frame.candidate, source: frame.sample, rect: rect,
                colour: candidate, on: context)
        overlay(frame.applied, source: frame.sample, rect: rect,
                colour: applied, on: context)
        text("Cyan: fresh ordinary border   Orange: fresh Beta candidate   Green: saved applied Beta",
             x: margin, y: top + CGFloat(d.h) + 18,
             size: 13, colour: muted, in: context)
        let ordinary = frame.ordinary, beta = frame.candidate
        text("Normal L\(ordinary.left) T\(ordinary.top) R\(ordinary.right) B\(ordinary.bottom)"
             + "   ·   Candidate L\(beta.left) T\(beta.top) R\(beta.right) B\(beta.bottom)",
             x: margin, y: top + CGFloat(d.h) + 45,
             size: 13, colour: white, in: context)
        text("Report is read-only. Beta masks affect statistics only; normal borders may crop exports.",
             x: margin, y: top + CGFloat(d.h) + 70,
             size: 12, colour: muted, in: context)
        try write(context, to: url)
    }
}
