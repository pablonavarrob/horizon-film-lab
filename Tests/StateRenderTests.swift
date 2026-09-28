import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
func runStateRenderTests() throws {
    let fm = FileManager.default
    let parent = ProcessInfo.processInfo.environment["HORIZON_TEST_TMP"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.temporaryDirectory
    let root = parent.appendingPathComponent("state-render-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // A new import should start with carrier handling enabled, even when the
    // current cache/session choice will later override that import default.
    let defaults = UserDefaults.standard
    let defaultsKeys = ["newCurve", "printLUT", "iccOnly"]
    let oldDefaults = Dictionary(uniqueKeysWithValues: defaultsKeys.map { ($0, defaults.object(forKey: $0)) })
    let oldPaperCurve = Paper.newCurve
    let oldPaperLUT = Paper.printLUT
    let oldPaperICC = Paper.outputICC
    let oldPaperSpan = Paper.directSpan
    let oldPaperKneeHigh = Paper.kneeHigh
    defer {
        for key in defaultsKeys {
            if let value = oldDefaults[key] ?? nil { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        Paper.newCurve = oldPaperCurve
        Paper.printLUT = oldPaperLUT
        Paper.outputICC = oldPaperICC
        Paper.directSpan = oldPaperSpan
        Paper.kneeHigh = oldPaperKneeHigh
    }

    defaults.removeObject(forKey: "newCurve")
    defaults.set("", forKey: "printLUT")
    defaults.set("", forKey: "iccOnly")

    // Undo is empty after closing a roll and cannot reach indices from it.
    let store = RollStore()
    precondition(store.carrierMaskEnabled, "new rolls begin with automatic carrier handling on")
    precondition(!store.canToggleCarrierMask, "carrier setting needs an opened roll")
    precondition(store.newCurve && Paper.newCurve,
                 "the shouldered contrast curve is the standard default")
    store.restoreGlobals()
    precondition(store.usesBuiltInPrintModel && !store.usesPrintLUT && !store.usesICCPrintModel,
                 "an empty external selection uses the built-in print model")

    // Menu availability follows the transform that actually loaded. A stale
    // or invalid LUT path falls back to built-in print controls; a valid LUT
    // makes Print Contrast inapplicable.
    let invalidLUT = root.appendingPathComponent("invalid.cube")
    try Data("not a cube".utf8).write(to: invalidLUT)
    store.printLUTPath = invalidLUT.path
    precondition(store.usesBuiltInPrintModel && !store.usesPrintLUT && !store.usesICCPrintModel,
                 "a rejected external file must not lock built-in Print Contrast")
    store.iccPath = root.appendingPathComponent("missing-print.icc").path
    precondition(store.usesBuiltInPrintModel && !store.usesICCPrintModel,
                 "a missing ICC must leave fallback RA-4 controls available")
    store.iccPath = ""
    let validLUT = root.appendingPathComponent("valid.cube")
    var cube = "TITLE \"Test LUT\"\nLUT_3D_SIZE 2\n"
    for b in 0...1 { for g in 0...1 { for r in 0...1 {
        cube += "\(r) \(g) \(b)\n"
    } } }
    try cube.write(to: validLUT, atomically: true, encoding: .utf8)
    store.printLUTPath = validLUT.path
    precondition(store.usesPrintLUT && !store.usesBuiltInPrintModel && !store.usesICCPrintModel,
                 "a loaded .cube selects LUT controls and disables built-in Print Contrast")
    store.printLUTPath = ""

    // A saved legacy preference remains an explicit choice; a missing value
    // uses the shouldered curve by default. Restore all defaults/global state
    // above so these checks cannot change the user's own settings.
    defaults.set(false, forKey: "newCurve")
    let legacyCurveStore = RollStore()
    precondition(!legacyCurveStore.newCurve, "an explicit saved legacy curve choice is preserved")
    legacyCurveStore.restoreGlobals()
    precondition(!Paper.newCurve && Paper.gradationRange.1 == 2,
                 "the saved legacy curve preference is mirrored into rendering")
    store.newCurve = true
    precondition(Paper.newCurve && Paper.gradationRange.1 == 3,
                 "the default shouldered curve exposes its third contrast step")

    store.frames = (0..<3).map { FrameItem(url: root.appendingPathComponent("old_\($0).ntg.tif")) }
    store.selected = 2
    store.mutate { $0.cyan = 4 }
    precondition(store.canUndo)
    precondition(store.closeRoll())
    store.frames = [FrameItem(url: root.appendingPathComponent("new.ntg.tif"))]
    store.undo(); store.redo()
    precondition(!store.canUndo && store.frames[0].edit.isNeutral)
    precondition(FrameItem.stem(of: root.appendingPathComponent("trip_cineon.ntg.tif")) == "trip_cineon")

    // A background progress update cannot hide a persistence failure.
    let workspace = Workspace(anyOf: root)
    try workspace.makeDirs()
    store.workspace = workspace
    precondition(!store.canToggleCarrierMask,
                 "a workspace without frames, captures, and an inversion recipe cannot toggle carrier handling")
    let corrupt = Data("unreadable edits".utf8)
    try corrupt.write(to: workspace.edits)
    precondition(!store.saveEdits())
    store.status = "3 frames ready"
    precondition(store.displayedStatus.contains("existing file preserved"))
    let preserved = try Data(contentsOf: workspace.edits)
    precondition(preserved == corrupt)
    try RollPersistence.write([String: Edit](), to: workspace.edits, backup: false)
    precondition(store.saveEdits() && store.displayedStatus == "3 frames ready")
    precondition(store.closeRoll())

    // Meter full image coordinates once, regardless of requested output crop.
    let w = 1600, h = 1100
    var pixels = [UInt16](repeating: 65535, count: w * h * 3)
    for y in 40..<(h - 40) {
        for x in 40..<(w - 40) {
            let value = UInt16(5000 + (x - 40) * 30 + ((x + y) % 7) * 80)
            for c in 0..<3 { pixels[(y * w + x) * 3 + c] = value }
        }
    }
    // Keep render-only fixtures out of the roll's capture directory so capture
    // discovery and the missing-originals check see only actual roll sources.
    let renderFixtures = root.appendingPathComponent("render-fixtures", isDirectory: true)
    try fm.createDirectory(at: renderFixtures, withIntermediateDirectories: true)
    let file = renderFixtures.appendingPathComponent("crop.ntg.tif")
    try Invert.writeMaster(pixels, w: w, h: h, to: file)
    let own = Invert.Border(left: 40, top: 40, right: 40, bottom: 40)
    let gate = Invert.Border(left: 80, top: 60, right: 80, bottom: 60)

    // Carrier requests are staged without changing the current statistics gate.
    // Returning to the applied choice cancels only while the cache is complete.
    let sourceCapture = workspace.captures.appendingPathComponent("carrier.tif")
    try fm.copyItem(at: file, to: sourceCapture)
    try Invert.run(dir: workspace.captures, layout: .rgb1, perFrameBase: true,
                   out: workspace.cache, carrierMaskEnabled: false)
    let carrierMaster = workspace.cache.appendingPathComponent("carrier.ntg.tif")
    var savedOff = Invert.loadSession(beside: workspace.cache)!
    savedOff.carrierBorders = ["carrier": own]
    try RollPersistence.write(savedOff, to: workspace.session)
    store.open(workspace)
    precondition(!store.carrierMaskEnabled)
    precondition(!store.carrierMaskRequiresReinversion)
    precondition(store.canToggleCarrierMask, "complete open rolls with captures can toggle carrier handling")
    let offGate = store.frames[0].statsGate!
    store.toggleCarrierMask()
    precondition(store.carrierMaskEnabled && store.carrierMaskRequiresReinversion)
    precondition(Invert.loadSession(beside: workspace.cache)?.pendingCarrierMaskEnabled == true)
    precondition(store.frames[0].statsGate?.left == offGate.left,
                 "requesting ON must leave the current OFF measurements visible")
    store.toggleCarrierMask()
    precondition(!store.carrierMaskEnabled && !store.carrierMaskRequiresReinversion)
    precondition(Invert.loadSession(beside: workspace.cache)?.pendingCarrierMaskEnabled == nil,
                 "toggling back cancels a pending choice when the cache is complete")

    // An incomplete cache keeps a pending request even when toggled back.
    let staleCapture = workspace.captures.appendingPathComponent("additional.tif")
    try fm.copyItem(at: file, to: staleCapture)
    precondition(store.canToggleCarrierMask, "open in-memory frames can still choose a recovery setting")
    store.toggleCarrierMask()
    precondition(store.carrierMaskEnabled && store.carrierMaskRequiresReinversion)
    store.toggleCarrierMask()
    precondition(!store.carrierMaskEnabled && store.carrierMaskRequiresReinversion
                 && Invert.loadSession(beside: workspace.cache)?.pendingCarrierMaskEnabled == false,
                 "an incomplete cache cannot cancel pending state by toggling back")
    try fm.removeItem(at: staleCapture)
    try Invert.run(dir: workspace.captures, layout: .rgb1, perFrameBase: true,
                   out: workspace.cache, forceRebuild: true, carrierMaskEnabled: false)
    let carrierBefore = try Data(contentsOf: carrierMaster)

    // Opening saved ON applies its mask. A pending OFF request shows the old
    // applied measurements while the toggle reflects the requested value.
    var savedOn = Invert.loadSession(beside: workspace.cache)!
    savedOn.carrierBorders = ["carrier": own]
    savedOn.carrierMaskEnabled = true
    savedOn.pendingCarrierMaskEnabled = nil
    try RollPersistence.write(savedOn, to: workspace.session)
    precondition(store.closeRoll())
    store.open(workspace)
    precondition(store.carrierMaskEnabled && !store.carrierMaskRequiresReinversion)
    let onGate = store.frames[0].statsGate!
    precondition(onGate.left == max(offGate.left, own.left) && onGate.top == max(offGate.top, own.top),
                 "a saved-on cache applies its persisted statistics mask")

    var pendingOff = Invert.loadSession(beside: workspace.cache)!
    pendingOff.pendingCarrierMaskEnabled = false
    try RollPersistence.write(pendingOff, to: workspace.session)
    precondition(store.closeRoll())
    store.open(workspace)
    precondition(!store.carrierMaskEnabled && store.carrierMaskRequiresReinversion,
                 "reopening a roll restores its pending requested setting")
    precondition(store.frames[0].statsGate?.left == onGate.left,
                 "a pending request does not change measurements applied to the existing cache")

    // Disabling prerequisites must disable the Settings toggle.
    let sourceBytes = try Data(contentsOf: sourceCapture)
    try fm.removeItem(at: sourceCapture)
    precondition(!store.canToggleCarrierMask, "missing original captures disable the toggle")
    try sourceBytes.write(to: sourceCapture)
    let sessionBytes = try Data(contentsOf: workspace.session)
    try fm.removeItem(at: workspace.session)
    precondition(!store.canToggleCarrierMask, "a missing saved session disables the toggle")
    try sessionBytes.write(to: workspace.session)

    precondition(store.carrierMaskRequiresReinversion)
    store.reinvert(selectedOnly: true)
    store.exportAll()
    store.correctRollColour()
    precondition(!store.isProcessing && store.displayedStatus.contains("Re-invert Whole Roll"))
    let carrierAfter = try Data(contentsOf: carrierMaster)
    precondition(carrierAfter == carrierBefore, "opening and rejecting work on pending state leaves masters untouched")

    // Whole-roll processing temporarily disables the toggle, even if the
    // current session already has enough information to display it.
    store.reinvert(selectedOnly: false)
    precondition(store.isProcessing && !store.canToggleCarrierMask)
    store.cancelProcessing()
    let processingDeadline = Date().addingTimeInterval(10)
    while store.isProcessing && Date() < processingDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    precondition(!store.isProcessing, "cancelled test inversion should settle before fixture cleanup")
    precondition(store.closeRoll())

    let full = try Master.load(file, frame: gate)
    let cropped = try Master.load(file, frame: gate, crop: own)
    let preview = try Master.load(file, maxEdge: FrameItem.previewEdge, frame: gate)
    precondition(full.ends.lo == cropped.ends.lo && full.ends.hi == cropped.ends.hi && full.ends.latd == cropped.ends.latd)
    precondition(full.ends.lo == preview.ends.lo && full.ends.hi == preview.ends.hi && full.ends.latd == preview.ends.latd)
    let term = Master.Terminator(icc: nil, lut: nil, mono: false)
    precondition(term.newCurve, "a default render snapshots the standard shouldered curve")
    let f = full.render16(Edit(), term), c = cropped.render16(Edit(), term)
    for y in stride(from: 0, to: cropped.height, by: 47) {
        for x in stride(from: 0, to: cropped.width, by: 53) {
            for channel in 0..<3 {
                precondition(f[((y + 40) * w + x + 40) * 3 + channel] == c[(y * cropped.width + x) * 3 + channel])
            }
        }
    }

    // Changes to globals after the render snapshot cannot change a batch.
    let savedKnee = Paper.kneeHigh, savedCrossover = Paper.crossoverHigh
    defer { Paper.kneeHigh = savedKnee; Paper.crossoverHigh = savedCrossover }
    Paper.kneeHigh = 0.7; Paper.crossoverHigh = 0.7
    precondition(full.render16(Edit(), term) == f)
    Paper.kneeHigh = savedKnee; Paper.crossoverHigh = savedCrossover
    var soft = Edit(); soft.gradation = -3
    precondition(Master.toneSlopes(soft, newCurve: false).lo == Master.toneSlopes(soft, newCurve: true).lo)
    let savedCurve = Paper.newCurve
    Paper.newCurve = true
    precondition(Paper.gradationRange.0 == -3)
    var strongest = Edit(); strongest.gradation = 3
    precondition(Master.toneSlopes(strongest).hi != Master.toneSlopes(strongest, newCurve: false).hi,
                 "default tone-slope calculation includes the standard third contrast step")
    Paper.newCurve = savedCurve

    // Real ImageIO export carries supplied photographic metadata, and refuses
    // an existing destination instead of silently replacing it.
    let exported = root.appendingPathComponent("photo.tif")
    let metadata = RollMetadata(title: "Holiday", stock: "Portra 400", photographDate: "2026-09-01")
    try cropped.write(Edit(), to: exported, as: .tiff, term, metadata: metadata.imageProperties)
    let source = CGImageSourceCreateWithURL(exported as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    let iptc = props[kCGImagePropertyIPTCDictionary] as? NSDictionary
    precondition(iptc?[kCGImagePropertyIPTCObjectName] as? String == "Holiday")
    let before = try Data(contentsOf: exported)
    do {
        try cropped.write(Edit(), to: exported, as: .tiff, term)
        preconditionFailure("export replaced an existing file")
    } catch {
        let after = try Data(contentsOf: exported)
        precondition(after == before)
    }

    func colourMaster(cast: Double, mixed: Bool = false) -> Master {
        let width = 72, height = 56
        var planes = [[UInt16]](repeating: [UInt16](repeating: 0, count: width * height), count: 3)
        for y in 0..<height { for x in 0..<width {
            let v = 0.24 + Double((x * 7 + y * 3) % 80) / 160
            let values = mixed && x < width / 2 ? [0.95, 0.10, 0.10] : [v + cast, v, v]
            for ch in 0..<3 { planes[ch][y * width + x] = Master.u16(values[ch]) }
        }}
        return Master(url: file, width: width, height: height, planes: planes,
                      frameMask: nil, ends: (0, 1, term.aim))
    }
    let neutral = colourMaster(cast: 0)
    let neutralResult = RollColourCorrection.estimate([.init(master: neutral, edit: Edit())], term: term)!
    precondition(abs(neutralResult.cyan) < 0.15 && abs(neutralResult.magenta) < 0.15 && abs(neutralResult.yellow) < 0.15)
    let cast = colourMaster(cast: 0.05, mixed: true)
    let result = RollColourCorrection.estimate([.init(master: cast, edit: Edit())], term: term)!
    let expected = 0.05 / Master.cmyUnit
    precondition(abs(result.cyan - expected * 2 / 3) < 0.2)
    precondition(abs(result.magenta + expected / 3) < 0.2 && abs(result.yellow + expected / 3) < 0.2)
    precondition(result.fraction > 0.3 && result.fraction < 0.7)
    var prior = Edit(); prior.autoCyan = result.cyan; prior.autoMagenta = result.magenta; prior.autoYellow = result.yellow
    let repeated = RollColourCorrection.estimate([.init(master: cast, edit: prior)], term: term)!
    precondition(result.cyan == repeated.cyan && result.magenta == repeated.magenta && result.yellow == repeated.yellow)
    precondition(RollColourCorrection.estimate([.init(master: cast, edit: prior)], term: term, cancelled: { true }) == nil)
    precondition(RollColourCorrection.estimate([.init(master: cast, edit: prior)],
        term: .init(icc: nil, lut: nil, mono: true)) == nil)
    let persisted = try JSONDecoder().decode(Edit.self, from: JSONEncoder().encode(prior))
    precondition(persisted == prior)
    print("state/render/colour regression tests passed")
}
