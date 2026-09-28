import Foundation
import ImageIO

/// In-process diagnostic coverage; the shell runner owns and EXIT-cleans TMP.
func runCarrierDiagnosticsTests() throws {
    guard let scratchPath = ProcessInfo.processInfo.environment["HORIZON_TEST_TMP"] else {
        preconditionFailure("run Tests/run-invert-edge-tests.sh for cleaned fixtures")
    }
    let scratch = URL(fileURLWithPath: scratchPath, isDirectory: true)
    let root = scratch.appendingPathComponent("carrier-diagnostics", isDirectory: true)
    let captures = root.appendingPathComponent("captures", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let output = root.appendingPathComponent("debug/borders", isDirectory: true)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)

    func capture(_ name: String, w: Int, h: Int, left: Int, right: Int) throws {
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let density = x < left || x >= w - right
                    ? 3.0 : ((x + y) % 2 == 0 ? 0.5 : 1.1)
                let value = UInt16((pow(10.0, -density) * 65535).rounded())
                let at = (y * w + x) * 3
                for channel in 0..<3 { rgb[at + channel] = value }
            }
        }
        try Invert.writeMaster(rgb, w: w, h: h,
            to: captures.appendingPathComponent(name + ".tif"))
    }
    try capture("scan-a", w: 1024, h: 256, left: 100, right: 80)
    try capture("scan-b", w: 1024, h: 256, left: 100, right: 80)
    try capture("scan-c", w: 1024, h: 256, left: 100, right: 80)
    try capture("odd-size", w: 640, h: 256, left: 0, right: 0)
    // Begin with a saved opt-out cache to exercise legacy diagnostics. Normal
    // new inversions now apply Beta automatically.
    try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true,
                   out: cache, useBorder: false, carrierMaskEnabled: false)

    let sessionURL = Invert.sessionURL(beside: cache)
    let manifestURL = CacheManifest.url(cache: cache)
    let masterURL = cache.appendingPathComponent("scan-a.ntg.tif")
    let sourceURL = captures.appendingPathComponent("scan-a.tif")
    let sessionBefore = try Data(contentsOf: sessionURL)
    let manifestBefore = try Data(contentsOf: manifestURL)
    let masterBefore = try Data(contentsOf: masterURL)
    let sourceBefore = try Data(contentsOf: sourceURL)

    let report = try Invert.writeBorderDiagnostics(dir: captures, layout: .rgb1,
        out: cache, destination: output)
    precondition(report.files.count == 6,
                 "two pooled size groups plus four frame previews are expected")
    precondition(report.preview.lastPathComponent == "pooled-001.png")
    precondition(report.summary.contains("2 capture size group(s)"))
    precondition(report.summary.contains(
        "PREVIEW ONLY · Carrier mask is off for the saved cache"))
    precondition(report.summary.contains("supplemental statistics masks"),
                 "repeated opaque carrier should generate Beta evidence")
    for file in report.files {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            preconditionFailure("diagnostic PNG is unreadable: \(file.lastPathComponent)")
        }
        precondition(image.width >= 320 && image.height >= 250)
    }
    let sessionAfter = try Data(contentsOf: sessionURL)
    let manifestAfter = try Data(contentsOf: manifestURL)
    let masterAfter = try Data(contentsOf: masterURL)
    let sourceAfter = try Data(contentsOf: sourceURL)
    precondition(sessionAfter == sessionBefore)
    precondition(manifestAfter == manifestBefore)
    precondition(masterAfter == masterBefore)
    precondition(sourceAfter == sourceBefore)

    for pending in [true, false] {
        var session = try JSONDecoder().decode(Invert.Session.self,
                                                from: Data(contentsOf: sessionURL))
        session.pendingCarrierMaskEnabled = pending
        let bytes = try JSONEncoder().encode(session)
        try bytes.write(to: sessionURL, options: .atomic)
        let pendingReport = try Invert.writeBorderDiagnostics(
            dir: captures, layout: .rgb1, out: cache, destination: output)
        precondition(pendingReport.summary.contains(
            "PREVIEW ONLY · Carrier mask requested \(pending ? "on" : "off"); full roll re-inversion required"))
        let saved = try Data(contentsOf: sessionURL)
        precondition(saved == bytes,
                     "pending setting must remain untouched by diagnostics")
    }

    // A pending ON request is applied by a full rebuild; the report then
    // inspects the committed masks read-only.
    var requestOn = Invert.loadSession(beside: cache)!
    requestOn.pendingCarrierMaskEnabled = true
    try RollPersistence.write(requestOn, to: sessionURL)
    try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true,
                   out: cache, useBorder: false)
    let appliedSession = Invert.loadSession(beside: cache)!
    precondition(appliedSession.carrierMaskEnabled && !appliedSession.carrierBorders.isEmpty
                 && appliedSession.pendingCarrierMaskEnabled == nil)
    let appliedSessionBytes = try Data(contentsOf: sessionURL)
    let appliedReport = try Invert.writeBorderDiagnostics(
        dir: captures, layout: .rgb1, out: cache, destination: output)
    precondition(appliedReport.summary.contains(
        "Beta analysis is applied to the saved cache · fresh evidence shown"))
    let afterAppliedReport = try Data(contentsOf: sessionURL)
    precondition(afterAppliedReport == appliedSessionBytes)

    var cancel = false
    let beforeFolders = Set((try FileManager.default.contentsOfDirectory(
        at: output, includingPropertiesForKeys: nil)).map(\.lastPathComponent))
    do {
        _ = try Invert.writeBorderDiagnostics(dir: captures, layout: .rgb1,
            out: cache, destination: output,
            cancellation: { cancel },
            progress: { if $0.hasPrefix("writing pooled") { cancel = true } })
        preconditionFailure("diagnostic report should cancel after first pooled PNG")
    } catch {
        precondition(cancel, "unexpected failure before cancellation: \(error)")
    }
    let afterFolders = Set((try FileManager.default.contentsOfDirectory(
        at: output, includingPropertiesForKeys: nil)).map(\.lastPathComponent))
    precondition(afterFolders == beforeFolders,
                 "a cancelled report must remove only its new output folder")

    // A two-frame roll still yields a useful labeled report without a Beta mask.
    let smallRoot = scratch.appendingPathComponent("carrier-diagnostics-no-evidence",
                                                 isDirectory: true)
    let smallCaptures = smallRoot.appendingPathComponent("captures", isDirectory: true)
    let smallCache = smallRoot.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: smallCaptures,
                                            withIntermediateDirectories: true)
    for name in ["first", "second"] {
        let rgb = [UInt16](repeating: 24000, count: 96 * 64 * 3)
        try Invert.writeMaster(rgb, w: 96, h: 64,
            to: smallCaptures.appendingPathComponent(name + ".tif"))
    }
    try Invert.run(dir: smallCaptures, layout: .rgb1,
                   perFrameBase: true, out: smallCache)
    let noEvidence = try Invert.writeBorderDiagnostics(dir: smallCaptures,
        layout: .rgb1, out: smallCache,
        destination: smallRoot.appendingPathComponent("debug", isDirectory: true))
    precondition(noEvidence.files.count == 3)
    precondition(noEvidence.summary.contains("No additional opaque carrier"))
    precondition(FileManager.default.fileExists(atPath: noEvidence.preview.path))
    print("carrier diagnostic regressions passed")
}
