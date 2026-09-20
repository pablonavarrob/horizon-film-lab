import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One frame of the roll: the master on disk, the operator's edit, and the
/// cached preview render. The master is never written to.
@MainActor
final class FrameItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    @Published var edit: Edit { didSet { if edit != oldValue { invalidate() } } }
    @Published private(set) var image: CGImage?
    /// DEV-SCOPE — the density trace and vectorscope for what is drawn now.
    @Published private(set) var scopes: Scopes?
    @Published private(set) var parade: Parade?
    @Published private(set) var loaded = false

    private var master: Master?

    var name: String { FrameItem.stem(of: url) }

    /// The master stem: the filename with whichever inverter's suffix it carries
    /// stripped. Both this and `export` derived it with identical inline code.
    nonisolated static func stem(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_cineon", with: "")
            .replacingOccurrences(of: ".ntg", with: "")
    }

    init(url: URL) {
        self.url = url
        self.edit = Edit()
    }

    /// Preview resolution. Minilab operators worked on an 800x600 CRT six-up;
    /// 1400px is generous by comparison and re-renders in ~6 ms.
    nonisolated static let previewEdge = 1400

    /// Drop the cached master so the next load re-reads it from disk. Used when
    /// a single frame is re-inverted — no reason to rebuild the whole roll.
    func reload() async {
        master = nil
        loaded = false
        await loadIfNeeded()
    }

    /// This frame's own detected rectangle, from session.json. The picture
    /// boundary, used only when an export is asked to crop to it.
    var frameRect: Invert.Border? = nil

    /// DEV-GATE — the roll's gate, which masks the STATISTICS. Not this frame's
    /// own rectangle: a frame whose detection returned 0 on a side would
    /// otherwise measure through the rebate. See `Invert.Border.gate(of:)`.
    var statsGate: Invert.Border? = nil

    func loadIfNeeded() async {
        guard master == nil else { return }
        let u = url, fr = statsGate
        let m = await Task.detached(priority: .userInitiated) {
            try? Master.load(u, maxEdge: FrameItem.previewEdge, frame: fr)
        }.value
        master = m
        loaded = true
        redraw()
    }

    /// DEV-SCOPE — the frame rectangle follows the picture through a rotation.
    /// Insets cycle L->T->R->B for each clockwise quarter turn.
    nonisolated static func turn(_ b: Invert.Border?, by turns: Int) -> Invert.Border? {
        guard let b else { return nil }
        var r = b
        for _ in 0..<(((turns % 4) + 4) % 4) {
            r = Invert.Border(left: r.bottom, top: r.left, right: r.top, bottom: r.right)
        }
        return r
    }

    private func invalidate() { redraw(); onEdit?() }

    /// Re-render with the current print model. Cheaper than reload(): the
    /// master and its measurements are unchanged, only the transfer.
    func refresh() { redraw() }

    /// Show the frame with corrections suspended. Not an edit -- the stored
    /// Edit is untouched, only what is drawn changes.
    var previewNeutral = false { didSet { if previewNeutral != oldValue { redraw() } } }

    private func redraw() {
        guard let master else { return }
        var shown = edit
        if previewNeutral {
            // Suspend the CORRECTIONS, keep the rotation. Rotation is geometry,
            // not a correction, and dropping it too made Before flip the frame
            // sideways -- which is the one thing that makes an A/B useless.
            shown = Edit()
            shown.quarterTurns = edit.quarterTurns
        }
        let img = try? master.cgImage(shown, bits: 8)
        image = img
        // DEV-SCOPE: measured on the pixels that were just produced, so the trace
        // cannot disagree with the picture next to it.
        let m = FrameItem.turn(master.frameMask, by: shown.quarterTurns)
        // Only when the panel is showing them: this is two extra passes over the
        // preview and there is no reason to pay for a readout nobody is looking at.
        // Only the one on show: each is a full pass over the preview.
        let want = RollStore.scopesVisible ? RollStore.scopeMode : nil
        parade = (want == .parade && img != nil) ? Parade.of(img!, mask: m) : nil
        // The cursor marks mid-grey. In the levels pipeline that is simply the
        // middle of the stretched range, which the terminator then renders --
        // there is no paper pivot to ask any more.
        scopes = want != .histogram ? nil : img.flatMap {
            Scopes.of($0, mask: m, anchor: master.midGreyFraction)
        }
    }


    var autoLight: Double { master?.autoLight ?? 0 }

    /// DEV-CAST — the mean of this frame's NEAR-NEUTRAL pixels, as rendered.
    ///
    /// Near-neutral only, and that restriction is the whole safety argument: a
    /// frame's overall average colour IS its scene colour, so correcting to it is
    /// grey-world, which renders cream sky and teal water (see DEV-DIRECT in
    /// Master.swift, where per-channel endpoints were rejected for exactly that).
    /// Pixels whose channels ALREADY nearly agree are the only ones that carry an
    /// opinion about neutral, which is what a lab analyser read.
    ///
    /// `n` is the vote count, and it doubles as the confidence: a strongly
    /// coloured scene has little near-neutral mass and should barely count. On the
    /// two real rolls it runs 1.5% of pixels on the most saturated frames against
    /// 54% on the flattest.
    ///
    /// MASKED BY THE ROLL GATE, like every other statistic in the app. It was not,
    /// and walked the whole rendered frame -- 7% of the votes on both test rolls
    /// came from OUTSIDE the gate, i.e. from the border. It happened not to move
    /// the answer (the keys round the same either way, R-G -2.37 against -2.15),
    /// because rebate renders black and carrier renders white and the level window
    /// below rejects both. That is luck, not design: the transition band at the
    /// film edge is flat and low-spread, exactly what this counts as neutral, and
    /// a fogged or scratched edge landing inside the window would vote.
    ///
    /// The mask is turned with the picture, the same way `redraw` turns it for the
    /// scopes -- `cgImage` applies `edit.quarterTurns`, so an unturned mask would
    /// sample the wrong edges on a rotated frame.
    func neutralSample(_ term: Master.Terminator) -> (r: Double, g: Double,
                                                      b: Double, n: Int)? {
        guard let master, let img = try? master.cgImage(edit, bits: 8, term),
              let data = img.dataProvider?.data as Data? else { return nil }
        let w = img.width, h = img.height, rb = img.bytesPerRow
        let comps = img.bitsPerPixel / 8
        guard comps >= 3, data.count >= rb * h else { return nil }
        let gate = FrameItem.turn(master.frameMask, by: edit.quarterTurns)
        let (gx0, gx1, gy0, gy1) = (gate ?? .init()).inner(w: w, h: h, least: 32)
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            // Every 2nd pixel each way: ~4x cheaper and the statistic is a mean
            // over tens of thousands of votes either way.
            for y in stride(from: gy0, to: gy1, by: 2) {
                let row = p + y * rb
                for x in stride(from: gx0, to: gx1, by: 2) {
                    let o = x * comps
                    let r = Double(row[o]), g = Double(row[o + 1]), b = Double(row[o + 2])
                    let lvl = (r + g + b) / 3
                    guard lvl > 60, lvl < 200 else { continue }
                    let spread = max(r, max(g, b)) - min(r, min(g, b))
                    guard spread < 18 else { continue }
                    sr += r; sg += g; sb += b; n += 1
                }
            }
        }
        guard n >= 500 else { return nil }
        return (sr / Double(n), sg / Double(n), sb / Double(n), n)
    }

    /// The frame's own stretch endpoints -- what actually drives the render.
    /// Printer lights used to sit here, but nothing downstream reads them.
    var levels: (lo: [Double], hi: [Double])? { master?.directLevels(edit) }
    /// Edits are persisted by the store into ONE roll file, not per-frame
    /// sidecars. They used to be written inside `.cache/`, which is the one
    /// directory documented as safe to delete — the only irreplaceable data in
    /// the whole pipeline was living in the bin.
    var onEdit: (() -> Void)?

    /// Export re-reads the master at FULL resolution and applies the identical
    /// table. Same function as the preview, so it is genuinely WYSIWYG.
    ///
    /// The border is a PARAMETER, not read from self. This ran off the main
    /// actor via `MainActor.assumeIsolated`, which does not "borrow" the actor
    /// -- it asserts you are already on it and traps if you are not. Export runs
    /// in `Task.detached`, so every save crashed. `loadIfNeeded` above had it
    /// right all along: capture the value on the actor, hand it over.
    ///
    /// `term` is the print terminator, captured on the main actor by the caller.
    /// Reading `Paper.outputICC` / `printLUT` / `monochrome` from this detached
    /// thread raced the menu bar: a print-model change mid-export split the batch
    /// across two terminators, and assigning those array-holding structs while
    /// this thread read them is an ARC race.
    nonisolated func export(_ edit: Edit, frame fr: Invert.Border?,
                            gate: Invert.Border?, to dir: URL,
                            tiff: Bool, jpeg: Bool,
                            cropToFrame: Bool = false,
                            term: Master.Terminator) throws {
        // DEV-GATE: statistics through the roll gate, crop through this frame's
        // own rectangle. Two different jobs, so two different rectangles.
        let full = try Master.load(url, maxEdge: nil, frame: gate,
                                   crop: cropToFrame ? fr : nil)
        let stem = FrameItem.stem(of: url)
        if tiff { try full.write(edit, to: dir.appendingPathComponent(stem + ".tif"),
                                 as: .tiff, quality: 0.92, term) }
        if jpeg { try full.write(edit, to: dir.appendingPathComponent(stem + ".jpg"),
                                 as: .jpeg, quality: 0.92, term) }
    }
}

/// Everything derived from a roll, in one visible subfolder of the folder you
/// imported. You always point the app at your capture folder; it finds the rest.
///
///   <captures>/
///     scan_..._1R.tiff …
///     Horizon/
///       edits.json          your corrections. tiny, precious, backs up with the folder
///       cache/              the masters. 1.9 GB, delete freely, rebuilds in 11s
///
/// Visible rather than dot-hidden on purpose: a hidden folder is one you forget
/// to back up, and this is the only irreplaceable output in the pipeline.
struct Workspace {
    let captures: URL
    /// `Horizon/`, except where a roll already has the old `Frontier/`
    /// workspace beside it -- that one keeps being used, so renaming the app does
    /// not orphan anyone's edits and cache. New rolls get the new name.
    var root: URL {
        let new = captures.appendingPathComponent("Horizon")
        let old = captures.appendingPathComponent("Frontier")
        let fm = FileManager.default
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) { return old }
        return new
    }
    var edits: URL { root.appendingPathComponent("edits.json") }
    var cache: URL { root.appendingPathComponent("cache") }
    var session: URL { root.appendingPathComponent("session.json") }

    /// Accepts the capture folder, or anything inside its workspace, and works
    /// back to the capture folder either way.
    init(anyOf url: URL) {
        var u = url
        if u.lastPathComponent == "cache" { u = u.deletingLastPathComponent() }
        if u.lastPathComponent == "Horizon" || u.lastPathComponent == "Frontier" {
            u = u.deletingLastPathComponent()
        }
        captures = u
    }

    func makeDirs() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    var hasMasters: Bool {
        let f = (try? FileManager.default.contentsOfDirectory(at: cache,
                    includingPropertiesForKeys: nil)) ?? []
        return f.contains { $0.lastPathComponent.hasSuffix(".ntg.tif") }
    }
}

@MainActor
final class RollStore: ObservableObject {
    @Published var frames: [FrameItem] = []
    /// Moving the selection while Before is held has to move the neutral view
    /// with it, otherwise the old frame stays stuck uncorrected.
    @Published var selected: Int = 0 {
        didSet { if selected != oldValue, showBefore { applyBefore() } }
    }
    @Published var workspace: Workspace?
    @Published var status: String = ""
    /// Copy / paste corrections between frames.
    @Published var clipboard: Edit?

    /// DEV-SCOPE — whether the panel shows the scopes. Static as well as
    /// published because FrameItem computes them during its own redraw and has no
    /// reference back to the store.
    /// Which instrument. One at a time: side by side in a 332 pt panel each was
    /// too small to read, which defeats the point of having them.
    enum ScopeMode: String, CaseIterable { case histogram, parade
        var label: String { self == .histogram ? "Histogram" : "Parade" }
    }
    nonisolated(unsafe) static var scopeMode: ScopeMode = ScopeMode(
        rawValue: UserDefaults.standard.string(forKey: "scopeMode") ?? "") ?? .histogram
    @Published var scopeMode: ScopeMode = ScopeMode(
        rawValue: UserDefaults.standard.string(forKey: "scopeMode") ?? "") ?? .histogram {
        didSet {
            UserDefaults.standard.set(scopeMode.rawValue, forKey: "scopeMode")
            RollStore.scopeMode = scopeMode
            for f in frames { f.refresh() }
        }
    }
    nonisolated(unsafe) static var scopesVisible =
        UserDefaults.standard.object(forKey: "showScopes") as? Bool ?? true
    @Published var showScopes: Bool =
        UserDefaults.standard.object(forKey: "showScopes") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showScopes, forKey: "showScopes")
            RollStore.scopesVisible = showScopes
            for f in frames { f.refresh() }
        }
    }

    /// The boot splash. True at launch, and again from the header's "?" button,
    /// which is the About box on the real machine too.
    @Published var showSplash = true
    /// DEV-RECENT
    @Published var recents: [URL] = RollStore.loadRecents()


    /// Undo history. One entry per USER ACTION, each holding every frame that
    /// action touched -- so undoing a Paste All is one press, not thirty.
    private var undoStack: [[(index: Int, edit: Edit)]] = []
    private var redoStack: [[(index: Int, edit: Edit)]] = []
    private static let undoDepth = 200
    var canUndo: Bool { !undoStack.isEmpty }

    /// EVERY correction goes through here. Ten separate call sites each
    /// remembering to snapshot is nine chances to forget; one mutator cannot be
    /// bypassed.
    func mutate(_ indices: [Int]? = nil, _ change: (inout Edit) -> Void) {
        let idx = (indices ?? [selected]).filter { frames.indices.contains($0) }
        guard !idx.isEmpty else { return }
        undoStack.append(idx.map { ($0, frames[$0].edit) })
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        for i in idx {
            var e = frames[i].edit
            change(&e)
            frames[i].edit = e
        }
    }

    func undo() {
        guard let step = undoStack.popLast() else { status = "nothing to undo"; return }
        redoStack.append(step.map { ($0.index, frames[$0.index].edit) })
        for s in step where frames.indices.contains(s.index) { frames[s.index].edit = s.edit }
        if let f = step.first { selected = f.index }
        status = step.count == 1 ? "undo" : "undo — \(step.count) frames"
    }

    func redo() {
        guard let step = redoStack.popLast() else { status = "nothing to redo"; return }
        undoStack.append(step.map { ($0.index, frames[$0.index].edit) })
        for s in step where frames.indices.contains(s.index) { frames[s.index].edit = s.edit }
        if let f = step.first { selected = f.index }
        status = step.count == 1 ? "redo" : "redo — \(step.count) frames"
    }

    /// Hold to see the frame with no corrections at all.
    /// Press-and-hold A/B, on the SELECTED frame only.
    ///
    /// This used to neutralise every frame in the roll, so holding Before flipped
    /// the whole strip along with the stage -- nothing to compare the stage
    /// against -- and re-rendered all eleven frames on each press.
    @Published var showBefore = false {
        didSet { applyBefore() }
    }
    /// Which frame is currently showing its uncorrected version. Held as the
    /// ITEM, not an index, because the selection can change while B is down.
    private weak var beforeFrame: FrameItem?

    private func applyBefore() {
        let want = showBefore ? current : nil
        if let old = beforeFrame, old !== want { old.previewNeutral = false }
        want?.previewNeutral = true
        beforeFrame = want
    }
    /// Per-frame frame rectangles from session.json. Masks statistics; only
    /// export ever crops, and only if asked.
    private var frameRects: [String: Invert.Border] = [:]
    /// Crop exports to the detected frame. OFF: borders are part of the picture
    /// unless you say otherwise, and the detection is not perfect.
    @Published var cropExport: Bool = UserDefaults.standard.bool(forKey: "cropExport") {
        didSet { UserDefaults.standard.set(cropExport, forKey: "cropExport") }
    }

    /// Export formats. Set from the menu bar so it stays out of the window.
    @Published var wantTIFF: Bool = UserDefaults.standard.object(forKey: "wantTIFF") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wantTIFF, forKey: "wantTIFF") }
    }
    @Published var wantJPEG: Bool = UserDefaults.standard.object(forKey: "wantJPEG") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wantJPEG, forKey: "wantJPEG") }
    }

    // ============================== DEV-MONO ==============================
    // The two properties of a ROLL, as opposed to a frame's corrections. They
    // are orthogonal and they act at different stages, which is why they are two
    // controls and not one list:
    //
    //   captureMode  how pixels are assembled  -> the INVERSION, needs re-invert
    //   monochrome   is this B&W film          -> the RENDER only, live
    //
    // A colour sensor can shoot B&W film and a mono sensor can shoot colour
    // negative, so neither implies the other.
    //
    // Both live in session.json rather than UserDefaults: they describe the roll,
    // so they must follow it rather than leak into the next one opened.
    // `captureMode` is written there by the inverter; `monochrome` is written by
    // `updateSession` too, because it can change without a re-invert.
    //
    // TO REMOVE: grep DEV-MONO. Both properties here, `RollPicker`, the two
    // Settings submenus, `Paper.monochrome`, the collapse in `render16`,
    // `Session.monochrome` and `Invert.suggestLayout`/`layoutAndFilm`.
    /// Installed by the menu bar at launch. Both submenus build their ticks once,
    /// but the roll's properties change from three places -- the import picker,
    /// Settings, and opening a roll -- so two of those left the menu showing the
    /// previous roll's state.
    nonisolated(unsafe) static var onRollProps: (() -> Void)?

    @Published var captureMode: Invert.Layout = .rgb3 {
        didSet {
            guard captureMode != oldValue else { return }
            updateSession { $0.layout = captureMode.rawValue }
            RollStore.onRollProps?()
        }
    }
    @Published var monochrome: Bool = false {
        didSet {
            Paper.monochrome = monochrome
            guard monochrome != oldValue else { return }
            updateSession { $0.monochrome = monochrome }
            status = monochrome ? "Film: black & white" : "Film: colour negative"
            for f in frames { f.refresh() }
            RollStore.onRollProps?()
        }
    }

    /// Read-modify-write of the one field the store owns. Film type is a render
    /// property, so changing it must NOT require re-inverting the roll -- but it
    /// still has to survive closing it.
    ///
    /// It writes to WHICHEVER ROLL IS OPEN, which is only correct because every
    /// import path now closes the previous roll before assigning any roll
    /// property. Assigning `monochrome` while the old roll was still open wrote
    /// the new roll's film type into the old roll's session.json, so a colour
    /// roll would later reopen as black and white.
    /// TRUE while an inversion is in flight. Set and cleared on the main actor
    /// only, so it needs no lock of its own.
    ///
    /// It closes two holes that shared one cause -- `session.json` having two
    /// writers with no coordination:
    ///
    ///  - `updateSession` below is a READ-MODIFY-WRITE of the same file
    ///    `Invert.run` writes WHOLESALE at the end of a run. Interleave them and
    ///    the loser's write is silently lost: a roll property toggled mid-invert
    ///    either vanishes or clobbers the freshly detected frame rectangles, and
    ///    the rectangles are what keep the rebate out of the endpoint percentiles.
    ///  - nothing stopped a SECOND `Invert.run` starting while the first was
    ///    running. Two runs write the same masters and the same session file from
    ///    two threads, and both entry points are one menu click away.
    ///
    /// Guarding the actions rather than the write, so a change is refused out loud
    /// instead of being dropped quietly.
    @Published private(set) var inverting = false

    private func updateSession(_ edit: (inout Invert.Session) -> Void) {
        // Refuse rather than race. `Invert.run` rewrites this file wholesale when
        // it finishes, so a write from here would either be lost or would undo the
        // borders it just detected.
        guard !inverting else {
            status = "busy inverting — try that again when it finishes"
            return
        }
        guard let ws = workspace,
              let d = try? Data(contentsOf: ws.session),
              var sess = try? JSONDecoder().decode(Invert.Session.self, from: d)
        else { return }
        edit(&sess)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(sess).write(to: ws.session)
    }


    /// Which print model renders the master. Empty = the built-in RA-4
    /// Archive simulation; otherwise the path to a .cube film-print LUT.
    @Published var printLUTPath: String = UserDefaults.standard.string(forKey: "printLUT") ?? "" {
        didSet {
            UserDefaults.standard.set(printLUTPath, forKey: "printLUT")
            applyPrintModel()
        }
    }

    func applyPrintModel() {
        if printLUTPath.isEmpty {
            Paper.printLUT = nil
            status = "Print model: Horizon RA-4 (built-in)"
        } else {
            do {
                let lut = try PrintLUT.load(URL(fileURLWithPath: printLUTPath))
                Paper.printLUT = lut
                status = "Print model: \(lut.name)"
            } catch {
                Paper.printLUT = nil
                status = "LUT failed: \(error.localizedDescription)"
            }
        }
        for f in frames { f.refresh() }
    }

    func chooseLUT() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.prompt = "Use this LUT"
        panel.message = "Choose a .cube film-print LUT (Cineon log input)"
        if panel.runModal() == .OK, let u = panel.url {
            // One print-model slot, one occupant -- and this direction was
            // missing. `chooseICC` cleared the LUT but not the reverse, so
            // loading a LUT over an ICC left BOTH set: the renderer took the LUT
            // (it branches on it first) while `modelName` still named the ICC,
            // and clearing the LUT silently brought the ICC back.
            iccPath = ""
            printLUTPath = u.path
        }
    }

    // ============================== DEV-ICC ==============================
    /// Path of the scanner ICC that replaces the whole render, or "" for off.
    ///
    /// A `scnr` profile has the entire rendering baked in -- inversion, balance
    /// and grade together -- so this is not a stage in our pipeline, it REPLACES
    /// it. Every correction goes inert while it is on, which the UI says out
    /// loud rather than leaving you to wonder why the buttons do nothing.
    @Published var iccPath: String = UserDefaults.standard.string(forKey: "iccOnly") ?? "" {
        didSet {
            UserDefaults.standard.set(iccPath, forKey: "iccOnly")
            applyICC()
        }
    }
    /// Load the profile into the print-emulation slot. Nothing special: it is one
    /// more print model, exactly like a .cube, and it is applied after the
    /// inversion for the same reason every print model is.
    ///
    /// The one check is that the profile does not itself invert. A profile built
    /// from raw negatives has the inversion baked in, and putting that here
    /// double-inverts -- reported like a bad LUT, not warned about in the UI.
    func applyICC() {
        Paper.outputICC = nil
        if iccPath.isEmpty {
            status = "Print model: \(Paper.modelName)"
        } else {
            do {
                let t = try ICCOnly.Transform.load(URL(fileURLWithPath: iccPath))
                guard !t.invertsTone else {
                    status = "\(t.name) inverts — that profile is for raw negatives, not for this slot"
                    for f in frames { f.refresh() }
                    return
                }
                Paper.outputICC = t
                status = "Print model: \(t.name)"
            } catch {
                status = "ICC failed: \(error.localizedDescription)"
            }
        }
        for f in frames { f.refresh() }
    }

    func chooseICC() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data,
                                     UTType(filenameExtension: "icm") ?? .data]
        panel.prompt = "Use this profile"
        panel.message = "Choose an ICC print emulation, applied after the inversion like a .cube LUT"
        if panel.runModal() == .OK, let u = panel.url {
            printLUTPath = ""          // one print-model slot, one occupant
            iccPath = u.path
        }
    }

    // =====================================================================

    /// Flat-field reference chosen in Settings. App-level rather than per-roll:
    /// the defect it corrects belongs to the camera, not the film. Captures in
    /// the roll folder named lcc*/flat*/blank* are still picked up automatically
    /// when nothing is set here.
    @Published var lccPaths: [String] = UserDefaults.standard.stringArray(forKey: "lccPaths") ?? [] {
        didSet { UserDefaults.standard.set(lccPaths, forKey: "lccPaths") }
    }
    var lccURLs: [URL] { lccPaths.map { URL(fileURLWithPath: $0) } }
    var lccLabel: String {
        lccPaths.isEmpty ? "none"
            : "\(lccPaths.count) file\(lccPaths.count == 1 ? "" : "s")"
    }

    func chooseLCC() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Use as LCC"
        panel.message = "Choose the flat-field capture(s) — one per LED for a trichromatic rig"
        panel.allowedContentTypes = [.tiff, .png]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var files: [URL] = []
        for u in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                files += ((try? FileManager.default.contentsOfDirectory(at: u,
                            includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["tif", "tiff", "png"].contains($0.pathExtension.lowercased()) }
            } else { files.append(u) }
        }
        lccPaths = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(\.path)
        status = "LCC set: \(lccLabel) — re-invert to apply"
    }


    func clearLCC() {
        lccPaths = []
        status = "LCC cleared — re-invert to apply"
    }


    var current: FrameItem? { frames.indices.contains(selected) ? frames[selected] : nil }

    /// A dropped folder: raw captures get inverted, already-inverted ones open.
    /// A dropped folder or file. Already inverted -> open. Raw captures -> invert.
    func accept(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        // A single dropped image: work in its parent folder.
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()

        // DEV-RECENT: a folder that has gone must LEAVE the list, not be pushed
        // back to the top of it. `recordRecent` ran before the attempt, so
        // clicking a stale entry re-promoted a path that no longer existed and
        // dead entries accumulated forever -- `loadRecents` filtered them out of
        // the view but never wrote the filtered list back.
        guard exists else {
            RollStore.forgetRecent(dir)
            recents = RollStore.loadRecents()
            status = "\(dir.lastPathComponent) is no longer there — removed from Recent"
            return
        }

        let ws = Workspace(anyOf: dir)
        if ws.hasMasters { recordRecent(dir); open(ws); return }

        let exts: Set<String> = ["tif", "tiff", "png"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: ws.captures,
                        includingPropertiesForKeys: nil)) ?? [])
        // Legacy: masters sitting loose in the folder.
        if files.contains(where: { $0.lastPathComponent.hasSuffix(".ntg.tif")
                                || $0.lastPathComponent.hasSuffix("_cineon.tif") }) {
            recordRecent(dir); openLoose(ws.captures); return
        }
        if files.contains(where: { exts.contains($0.pathExtension.lowercased()) }) {
            recordRecent(dir); newRoll(ws.captures); return
        }
        // Recorded only on success, so a folder with nothing openable in it does
        // not earn a place in the list either.
        status = "Nothing to open in \(ws.captures.lastPathComponent)"
    }

    /// Back to the idle window and its recent list. Edits are already saved on
    /// every change, so there is nothing to flush -- but save once more anyway,
    /// because losing corrections to a menu item nobody expected to be
    /// destructive is not a trade worth making.
    func closeRoll() {
        guard !frames.isEmpty else { return }
        saveEdits()
        let name = workspace?.captures.lastPathComponent ?? "roll"
        frames = []
        selected = 0
        workspace = nil          // before the resets below: see `updateSession`
        frameRects = [:]
        captureMode = .rgb3
        monochrome = false
        Paper.monochrome = false
        recents = RollStore.loadRecents()      // DEV-RECENT: pick up this roll
        status = "Closed \(name)"
    }

    func open(_ ws: Workspace) {
        workspace = ws
        // DEV-MONO: the roll's own properties, restored before anything renders.
        // Re-invert reads captureMode rather than re-inspecting the files, so an
        // operator's choice is not quietly overturned by a second guess.
        //
        // ASSIGNED UNCONDITIONALLY, defaults included. Restoring them only when
        // the session decoded left them at the PREVIOUS roll's values, so a
        // colour roll opened after a B&W one rendered black and white -- and the
        // loose-master path (no session.json at all) always took that branch.
        let sess = (try? Data(contentsOf: ws.session)).flatMap {
            try? JSONDecoder().decode(Invert.Session.self, from: $0)
        }
        frameRects = sess?.frameBorders ?? [:]
        captureMode = sess.flatMap { Invert.Layout(rawValue: $0.layout) } ?? .rgb3
        monochrome = sess?.monochrome ?? false
        Paper.monochrome = monochrome
        // RESTORE THE FLAT THE ROLL WAS INVERTED WITH.
        //
        // `lccPaths` is app-wide, so re-inverting a roll used whatever flat happened
        // to be selected -- or none. The session records what was actually used, so a
        // re-invert can reproduce the roll instead of quietly making a different one.
        // This is how a roll made with a flat stopped matching itself after the bundle
        // rename reset UserDefaults and the selection went empty.
        //
        // Only when the session names files that still exist; otherwise the current
        // selection is left alone, because one flat per session reused across rolls
        // is the intended workflow.
        if let recorded = sess?.lcc, !recorded.isEmpty {
            let live = recorded.filter { FileManager.default.fileExists(atPath: $0) }
            if live.count == recorded.count {
                if lccPaths != live { lccPaths = live }
            } else {
                status = "This roll was inverted with a flat that is no longer at "
                       + "\(recorded.first ?? "?") — re-select it before re-inverting"
            }
        }
        openLoose(ws.cache, keepWorkspace: true)
    }

    /// `edits.json` lives in the workspace beside the RAW CAPTURES, one per roll,
    /// holding every frame's corrections. A few hundred bytes, and it survives
    /// deleting the 1.9 GB cache.
    private func loadEdits() {
        guard let ws = workspace,
              let d = try? Data(contentsOf: ws.edits),
              let map = try? JSONDecoder().decode([String: Edit].self, from: d) else { return }
        for f in frames { if let e = map[f.name] { f.edit = e } }
    }

    func saveEdits() {
        guard let ws = workspace else { return }
        // MERGED with what is on disk, not rebuilt from `frames`.
        //
        // `frames` holds only the masters currently in the cache, so rebuilding
        // from it deleted the corrections of every frame that was not loaded --
        // after a `--only` re-invert, or when the cache is opened before every
        // master exists. loadEdits assigns into FrameItem.edit, whose didSet calls
        // this, so the loss happened at OPEN and was permanent.
        // REFUSE to write over a file we cannot read. Otherwise an unparseable
        // edits.json becomes an empty merge, every frame looks neutral, and the
        // branch below deletes it -- turning a recoverable file into no file.
        let onDisk = try? Data(contentsOf: ws.edits)
        var map: [String: Edit] = [:]
        if let onDisk {
            guard let decoded = try? JSONDecoder().decode([String: Edit].self, from: onDisk)
            else {
                status = "edits.json is unreadable — leaving it alone"
                return
            }
            map = decoded
        }
        // In name order so a later duplicate wins, as `uniquingKeysWith` did:
        // `name` strips both "_cineon" and ".ntg", so two files can collide.
        for f in frames {
            if f.edit.isNeutral { map.removeValue(forKey: f.name) } else { map[f.name] = f.edit }
        }
        if map.isEmpty {
            try? FileManager.default.removeItem(at: ws.edits)   // don't litter clean rolls
            return
        }
        try? ws.makeDirs()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(map) else { return }
        try? d.write(to: ws.edits)
    }

    func openLoose(_ dir: URL, keepWorkspace: Bool = false) {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir,
                        includingPropertiesForKeys: nil)) ?? [])
            .filter { let n = $0.lastPathComponent
                      return n.hasSuffix(".ntg.tif")          // Swift inverter
                          || n.hasSuffix("_cineon.tif")       // n2c_v5.py
                          || n.hasSuffix("_cineon.tiff") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else {
            status = "No inverted frames in \(dir.lastPathComponent)"; return
        }
        if !keepWorkspace {
            // Legacy loose masters, no session.json: the roll's properties are
            // unknown, so they must be DEFAULTED rather than inherited from
            // whatever was open before.
            workspace = Workspace(anyOf: dir)
            captureMode = .rgb3
            monochrome = false
            Paper.monochrome = false
        }
        frames = urls.map(FrameItem.init)
        // DEV-GATE: the detector gate always, plus the pooled-profile one when
        // the flag is on. Union, so it can only ever exclude more.
        let detector = Invert.Border.gate(of: frameRects)
        let gate = detector
        for f in frames {
            f.onEdit = { [weak self] in self?.saveEdits() }
            f.frameRect = frameRects[f.name]
            f.statsGate = gate
        }
        selected = 0
        status = "\(frames.count) frames ready"
        loadEdits()
        Task { await loadAll() }
    }

    /// Load the roll, SELECTED FRAME FIRST and then a few at a time.
    ///
    /// This was a plain sequential loop from frame 0, so opening a roll meant
    /// waiting for every earlier frame before the one you were looking at
    /// appeared -- and clicking frame 9 of 11 showed a spinner for eight loads
    /// that nobody had asked for. Loading what is on screen first is most of what
    /// "seamless" means here; the rest is just not doing it one at a time.
    ///
    /// Three at a time, matching the inverter: each load holds a 180 MB source
    /// buffer while it decimates, so this is bandwidth bound too.
    private func loadAll() async {
        let order = [selected] + frames.indices.filter { $0 != selected }
        let items = order.map { frames[$0] }        // hoisted: the group body is nonisolated
        var loaded = 0
        var cursor = 0
        await withTaskGroup(of: Void.self) { group in
            while cursor < items.count, cursor < 3 {
                let f = items[cursor]; cursor += 1
                group.addTask { await f.loadIfNeeded() }
            }
            while await group.next() != nil {
                loaded += 1
                status = "reading \(loaded) of \(items.count)…"
                if cursor < items.count {
                    let f = items[cursor]; cursor += 1
                    group.addTask { await f.loadIfNeeded() }
                }
            }
        }
        status = "\(frames.count) frames ready"
    }

    func select(_ i: Int) { if frames.indices.contains(i) { selected = i } }
    func step(_ d: Int) { select(min(max(selected + d, 0), frames.count - 1)) }

    // MARK: Key actions, in the machine's units and signs
    func bump(cyan: Int = 0, magenta: Int = 0, yellow: Int = 0, density: Int = 0) {
        mutate {
            $0.cyan = ($0.cyan + cyan).clamped(Paper.cmyRange)
            $0.magenta = ($0.magenta + magenta).clamped(Paper.cmyRange)
            $0.yellow = ($0.yellow + yellow).clamped(Paper.cmyRange)
            $0.density = ($0.density + density).clamped(Paper.densRange)
        }
    }
    func rotate(_ turns: Int = 1) {
        mutate { $0.quarterTurns = ($0.quarterTurns + turns) % 4 }
    }
    /// Rotate the whole roll — scans off the same carrier share an orientation.
    func rotateAll(_ turns: Int = 1) {
        mutate(Array(frames.indices)) { $0.quarterTurns = ($0.quarterTurns + turns) % 4 }
    }
    func resetColour() { mutate { $0.cyan = 0; $0.magenta = 0; $0.yellow = 0 } }
    func resetDensity() { mutate { $0.density = 0 } }
    func setHigh(_ g: Paper.Grade) { mutate { $0.high = g } }
    func setShadow(_ g: Paper.Grade) { mutate { $0.shadow = g } }
    /// Gradation Selection, -3...+2 = Soft3...Hard2.
    func setGradation(_ g: Int) {
        mutate { $0.gradation = min(max(g, Paper.gradationRange.0),
                                    Paper.gradationRange.1) }
    }

    // ============================== DEV-CURVE ==============================
    /// Shoulder on every contrast path, Contrast one step longer at the top, and
    /// DRANGE reduced to the wide endpoints. Behind a flag so it comes out in one
    /// line if it is not wanted; off reproduces today byte-for-byte.
    /// EVERY DEFAULT THAT MIRRORS INTO A `Paper` GLOBAL IS PUSHED HERE, ONCE.
    ///
    /// `didSet` does not fire for a property's initial value, so a mirrored
    /// default is inert until the user changes it. Two ad-hoc calls in
    /// `main.swift` did this for the print model; `newCurve` was added without
    /// one, so a stored `newCurve = 1` gave the NEW Contrast labels on the OLD
    /// maths — `gradationRange` stayed (-3, 2), Very Strong clamped to Strong and
    /// read as unclickable, and the shoulder never applied. `drangeStrong` had
    /// the same fault before it was deleted.
    ///
    /// Register anything new here rather than adding another line to `main.swift`.
    func restoreGlobals() {
        applyPrintModel()                    // Paper.printLUT
        applyICC()                           // Paper.outputICC
        Paper.newCurve = newCurve            // DEV-CURVE
        Paper.kneeHigh = highlightRolloff    // DEV-CURVE
        Paper.directSpan = printContrast
    }

    /// DEV-CURVE — where the highlight roll-off starts. ICC / .cube only: the
    /// built-in curve has its own shoulder and never clamps, so this cannot and
    /// should not touch it.
    @Published var highlightRolloff: Double = {
        let v = UserDefaults.standard.double(forKey: "highlightRolloff")
        return [0.20, 0.30, 0.45].contains(v) ? v : 0.30
    }() {
        didSet {
            UserDefaults.standard.set(highlightRolloff, forKey: "highlightRolloff")
            Paper.kneeHigh = highlightRolloff
            for f in frames { f.refresh() }
        }
    }

    /// The built-in curve's span. Built-in terminator only.
    @Published var printContrast: Double = {
        let v = UserDefaults.standard.double(forKey: "printContrast")
        return [1.2, 1.4, 1.6].contains(v) ? v : 1.4
    }() {
        didSet {
            UserDefaults.standard.set(printContrast, forKey: "printContrast")
            Paper.directSpan = printContrast
            for f in frames { f.refresh() }
        }
    }

    @Published var newCurve: Bool = UserDefaults.standard.bool(forKey: "newCurve") {
        didSet {
            UserDefaults.standard.set(newCurve, forKey: "newCurve")
            Paper.newCurve = newCurve
            // A stored +3 is out of range with the flag off, so pull it back --
            // otherwise turning the flag off would leave frames on a setting the
            // panel cannot show or undo.
            if !newCurve {
                let over = frames.indices.filter { frames[$0].edit.gradation > 2 }
                if !over.isEmpty {
                    mutate(over) { $0.gradation = 2 }
                }
            }
            for f in frames { f.refresh() }
            status = newCurve ? "Contrast: shouldered curve, DRANGE = range only"
                              : "Contrast: as shipped"
        }
    }
    // =======================================================================
    // ============================== DEV-CAST ==============================
    /// The ROLL's residual colour cast, in key presses. A METER: it reports, and
    /// `applyRollCast` is a separate, explicit action.
    ///
    /// WHY THE ROLL AND NOT THE FRAME. Measured over both rolls, pooling
    /// near-neutral pixels (`FrameItem.neutralSample`):
    ///
    ///                  roll cast            per-frame scatter (sd)
    ///   markesteijn   -1.3 / -2.3 keys        1.7 / 2.2 keys
    ///   new-captures  +1.8 / +0.7 keys        2.4 / 1.8 keys
    ///
    /// The per-frame scatter is as large as the cast itself, so a per-frame
    /// reading cannot separate rig cast from scene colour -- which is the same
    /// conclusion the seven deleted AWB mechanisms reached. Pooling the roll
    /// divides that scatter by sqrt(n): 37 frames puts the roll figure inside
    /// about +-0.3 keys, which is worth acting on.
    ///
    /// It is roll-level, and that does not break "every frame is its own world":
    /// nothing here feeds the render. It hands the operator a number, the same way
    /// a lab analyser did, and the operator decides. `hold()` and `pasteAll()` are
    /// already roll-wide manual actions of exactly this kind.
    ///
    /// Weighted by vote count, so a saturated frame with 1.5% near-neutral mass
    /// barely counts against a flat one with 54%.
    func measureRollCast() -> (c: Int, m: Int, y: Int, frames: Int, mass: Double)? {
        guard !frames.isEmpty else { return nil }
        let term = Master.Terminator.current
        var sr = 0.0, sg = 0.0, sb = 0.0, tot = 0, used = 0, pix = 0
        for f in frames {
            guard let s = f.neutralSample(term) else { continue }
            let wgt = Double(s.n)
            sr += s.r * wgt; sg += s.g * wgt; sb += s.b * wgt
            tot += s.n; used += 1; pix += s.n
        }
        guard used > 0, tot > 0 else { return nil }
        let r = sr / Double(tot), g = sg / Double(tot), b = sb / Double(tot)
        let mean = (r + g + b) / 3
        // A key lowers its own channel. Measured through the ICC at the 5% step,
        // one key moves a channel about 2.4 output codes -- one constant, not a
        // per-channel calibration, so re-measuring after applying is the honest
        // way to converge. It normally takes one round.
        let perKey = 2.4
        func keys(_ v: Double) -> Int { Int(((v - mean) / perKey).rounded()) }
        return (c: keys(r), m: keys(g), y: keys(b), frames: used,
                mass: Double(pix) / Double(max(tot, 1)))
    }

    /// Dial the measured cast onto every frame. Explicit, undoable, and additive —
    /// so measuring again reports what is LEFT, not the same number twice.
    func applyRollCast() {
        guard let k = measureRollCast() else {
            status = "not enough near-neutral pixels to measure a cast"
            return
        }
        guard k.c != 0 || k.m != 0 || k.y != 0 else {
            status = "roll is already neutral to within a key"
            return
        }
        mutate(Array(frames.indices)) {
            $0.cyan = ($0.cyan + k.c).clamped(Paper.cmyRange)
            $0.magenta = ($0.magenta + k.m).clamped(Paper.cmyRange)
            $0.yellow = ($0.yellow + k.y).clamped(Paper.cmyRange)
        }
        status = "applied C\(Edit.keyLabel(k.c)) M\(Edit.keyLabel(k.m)) "
            + "Y\(Edit.keyLabel(k.y)) to all \(frames.count) frames"
    }

    func reportRollCast() {
        guard let k = measureRollCast() else {
            status = "not enough near-neutral pixels to measure a cast"
            return
        }
        status = "roll cast C\(Edit.keyLabel(k.c)) M\(Edit.keyLabel(k.m)) "
            + "Y\(Edit.keyLabel(k.y))  (\(k.frames) frames, "
            + String(format: "%.0f%% neutral mass)", k.mass * 100)
    }
    // ======================================================================

    // ============================== DEV-REVIEW ==============================
    /// The consistency pass: N frames at judgeable size instead of one big
    /// preview. A view, not a mode — the keys keep acting on the selection.
    @Published var reviewGrid = false
    /// 6, 8 or 12. Persisted because it is a preference about your screen.
    @Published var gridSize: Int = {
        let v = UserDefaults.standard.integer(forKey: "gridSize")
        return [6, 8, 12].contains(v) ? v : 6
    }() {
        didSet { UserDefaults.standard.set(gridSize, forKey: "gridSize") }
    }
    // ========================================================================

    func copyEdit() {
        guard let f = current else { return }
        clipboard = f.edit
        status = "copied C\(f.edit.cyan) M\(f.edit.magenta) Y\(f.edit.yellow) D\(f.edit.density)"
    }
    func pasteEdit() {
        guard let c = clipboard else { return }
        mutate { e in
            let turns = e.quarterTurns          // orientation is per frame
            e = c; e.quarterTurns = turns
        }
        status = "pasted onto frame \(selected + 1)"
    }
    func pasteAll() {
        guard let c = clipboard else { return }
        mutate(Array(frames.indices)) { e in
            let turns = e.quarterTurns
            e = c; e.quarterTurns = turns
        }
        status = "pasted onto all \(frames.count) frames"
    }
    /// Current frame only. This used to fan out to every frame, which meant a
    /// spurious Binding.set during layout rewrote the whole roll and wrote 11
    /// sidecars on launch. Roll-wide changes go through `hold()`, explicitly.
    /// HOLD carries the current correction forward, exactly like the key.
    func hold() {
        guard let f = current else { return }
        let src = f.edit
        mutate(Array((selected + 1)..<frames.count)) { $0 = src }
        status = "held C\(f.edit.cyan) M\(f.edit.magenta) Y\(f.edit.yellow) D\(f.edit.density) onto \(frames.count - selected - 1) frames"
    }

    func exportAll(selectedOnly: Bool = false) {
        let tiff = wantTIFF, jpeg = wantJPEG, cropped = cropExport
        guard tiff || jpeg else {
            status = "No export format selected — see Settings in the menu bar"; return
        }
        let chosen = selectedOnly ? (current.map { [$0] } ?? []) : frames
        guard !chosen.isEmpty else { status = "Nothing to export"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export here"
        panel.message = selectedOnly ? "Export this frame" : "Export \(chosen.count) frames"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let jobs = chosen.map { ($0, $0.edit, $0.frameRect, $0.statsGate) }
        // Snapshot the print terminator HERE, on the main actor, so the whole
        // batch renders through one of them even if the menu changes mid-export.
        let term = Master.Terminator.current
        status = "exporting 0/\(jobs.count)…"
        Task.detached(priority: .userInitiated) {
            for (n, job) in jobs.enumerated() {
                do { try job.0.export(job.1, frame: job.2, gate: job.3, to: dir,
                                      tiff: tiff, jpeg: jpeg,
                                      cropToFrame: cropped, term: term) }
                catch {
                    let m = error.localizedDescription
                    await MainActor.run { self.status = "export failed: \(m)" }
                    return
                }
                await MainActor.run { self.status = "exporting \(n + 1)/\(jobs.count)…" }
            }
            await MainActor.run {
                self.status = "exported \(jobs.count) frames to \(dir.lastPathComponent)"
            }
        }
    }

    /// Pick a folder of RAW CAPTURES, invert them, and open the result. No
    /// terminal, no layout question: the file shapes determine the layout.
    func newRoll(_ folder: URL? = nil) {
        // One inversion at a time -- reachable from the menu, the idle screen and
        // a drop, so the guard belongs here rather than at each caller.
        guard !inverting else { status = "already inverting"; return }
        let dir: URL
        var pick: RollPicker? = nil
        if let folder { dir = folder } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Invert this roll"
            panel.message = "Choose a folder of raw captures"
            let p = attachRollPicker(panel)
            guard panel.runModal() == .OK, let u = panel.url else { return }
            pick = p; dir = u
        }

        // LCC/flat captures EXCLUDED, as the inverter excludes them. Counting a
        // flat changed the file count's parity, which is what decides one-shot
        // from three-shot, so a single flat in the folder flipped the layout.
        let urls = Self.captures(in: dir)
        guard !urls.isEmpty else {
            status = "No captures found in \(dir.lastPathComponent)"; return
        }
        // Close the previous roll BEFORE assigning any roll property: the
        // `monochrome` didSet persists to the open roll's session.json.
        closeRoll()
        if let pick {
            applyRollPicker(pick, folder: dir)
        } else if let s = Invert.suggestLayout(urls) {
            // A dropped folder never saw the picker, so seed it from the files.
            captureMode = s.layout
            monochrome = s.monochrome
            Paper.monochrome = monochrome
        }
        let layout = captureMode
        let ws = Workspace(anyOf: dir)
        // Snapshot main-actor settings before the detached task, not inside it.
        let lcc = lccURLs
        let bw = monochrome
        frames = []
        status = "inverting \(urls.count) captures as \(layout.rawValue)…"
        inverting = true
        Task.detached(priority: .userInitiated) {
            do {
                try ws.makeDirs()
                try Invert.run(dir: ws.captures, layout: layout, perFrameBase: true,
                               out: ws.cache, lcc: lcc, monochrome: bw) { msg in
                    Task { @MainActor in self.status = msg }
                }
            } catch {
                let m = error.localizedDescription
                await MainActor.run {
                    self.inverting = false
                    self.status = "inversion failed: \(m)"
                }
                return
            }
            await MainActor.run { self.inverting = false; self.open(ws) }
        }
    }

    /// Re-run the inversion. Nothing is destroyed that cannot be regenerated,
    /// and your corrections in edits.json are untouched — they key off the frame
    /// name, not the master's contents.
    func reinvert(selectedOnly: Bool) {
        guard let ws = workspace else { status = "No roll open"; return }
        // One inversion at a time. Both entry points are a single click away and
        // two runs write the same masters and the same session file.
        guard !inverting else { status = "already inverting"; return }
        let only: Set<String>? = selectedOnly ? current.map { [$0.name] } : nil
        if selectedOnly && only == nil { status = "No frame selected"; return }
        let lcc = lccURLs
        // DEV-MONO: the operator's choice, NOT a second guess at the files. This
        // used to call detectLayout again, which would have silently overturned
        // any capture mode picked at import.
        let layout = captureMode
        let bw = monochrome
        let target = selectedOnly ? current : nil
        let label = selectedOnly ? (current?.name ?? "") : "\(frames.count) frames"
        status = "re-inverting \(label)…"

        let keepSel = selected
        inverting = true
        Task.detached(priority: .userInitiated) {
            do {
                let caps = ((try? FileManager.default.contentsOfDirectory(at: ws.captures,
                                includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["tif", "tiff", "png"].contains($0.pathExtension.lowercased())
                              && !Invert.isLCC($0) }
                guard !caps.isEmpty else {
                    await MainActor.run {
                        self.inverting = false
                        self.status = "cannot read captures"
                    }
                    return
                }
                try Invert.run(dir: ws.captures, layout: layout, perFrameBase: true,
                               out: ws.cache, only: only,
                               lcc: lcc, monochrome: bw) { msg in
                    Task { @MainActor in self.status = msg }
                }
            } catch {
                let m = error.localizedDescription
                await MainActor.run {
                    self.inverting = false
                    self.status = "re-invert failed: \(m)"
                }
                return
            }
            // Cleared BEFORE the reload paths below, because those call
            // `updateSession` indirectly and it now refuses while this is set.
            await MainActor.run { self.inverting = false }
            // Only the frame that changed is re-read. Rebuilding the whole roll
            // meant re-decoding every master to fix one frame.
            if let target {
                await target.reload()
                await MainActor.run {
                    // The rectangle it was just re-detected with. Without this the
                    // store kept the OLD one, so turning border detection off and
                    // re-inverting -- the documented escape hatch for a misread
                    // frame -- left the bad mask in place.
                    if let sess = Invert.loadSession(beside: ws.cache) {
                        let d0 = Invert.Border.gate(of: self.frameRects)
                        let was = d0
                        self.frameRects = sess.frameBorders
                        // DEV-GATE: re-detecting one frame can WIDEN the roll's
                        // gate, and the gate masks every frame's statistics --
                        // so when it moves, every frame has to re-measure.
                        // Only then: this path exists to avoid rebuilding the
                        // whole roll to fix one frame, and a re-invert usually
                        // does not touch the worst side.
                        let d1 = Invert.Border.gate(of: self.frameRects)
                        let gate = d1
                        for f in self.frames {
                            f.frameRect = self.frameRects[f.name]
                            f.statsGate = gate
                        }
                        if gate != was {
                            let stale = self.frames.filter { $0 !== target }
                            Task { for f in stale { await f.reload() } }
                        }
                    }
                    self.status = "re-inverted \(label)"
                }
            } else {
                await MainActor.run {
                    self.open(ws)
                    self.selected = min(keepSel, max(self.frames.count - 1, 0))
                    self.status = "re-inverted \(label)"
                }
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open roll"
        let pick = attachRollPicker(panel)
        if panel.runModal() == .OK, let u = panel.url {
            closeRoll()                  // before any roll property is assigned
            applyRollPicker(pick, folder: u)
            accept(u)
        }
    }

}


extension RollStore {
    // ============================== DEV-MONO ==============================
    // The import picker: ONE question, in the panel the operator is already in.
    //
    // It asks how many shots make a frame, and nothing else. It used to also ask
    // mono-vs-colour and colour-vs-B&W, which was two redundant questions:
    //
    //  - whether the files are single-channel is a FACT about them, read with
    //    `Invert.monoCaptures`, never something to be told;
    //  - a single mono plane has no colour information in it, so "single shot
    //    mono" and "black & white" were the same statement made twice.
    //
    // What is left is the one thing no file can answer: whether three unsuffixed
    // captures are three exposures of one frame or three separate photographs.
    // Everything else is derived, and the film popup disables itself when the
    // derivation has already settled it.

    func attachRollPicker(_ panel: NSOpenPanel) -> RollPicker {
        let pick = RollPicker()
        pick.start(captureMode: captureMode, monochrome: monochrome)
        panel.accessoryView = pick.box
        panel.isAccessoryViewDisclosed = true
        // The picker is the panel's delegate so it can re-seed from the folder as
        // the operator navigates. `panel.url` is nil until the modal is running,
        // so seeding once here read nothing at all.
        panel.delegate = pick
        return pick
    }

    func applyRollPicker(_ pick: RollPicker, folder: URL) {
        let caps = Self.captures(in: folder)
        let mono = Invert.monoCaptures(caps) ?? false
        // If the operator never touched the popup, the FILES decide -- not
        // whatever the popup happens to be showing. Without this, importing a
        // folder whose capture count is not a multiple of three while the popup
        // still read "three shots per frame" produced an empty roll.
        let three = pick.userChose ? pick.threeShot
                                   : (Invert.suggestLayout(caps).map {
                                        $0.layout == .rgb3 || $0.layout == .mono3 } ?? true)
        let r = Invert.layoutAndFilm(threeShot: three, mono: mono)
        captureMode = r.layout
        // `r.monochrome` forces B&W where it is not a choice (a single mono
        // plane); otherwise the popup decides, in BOTH directions.
        monochrome = r.monochrome || (!r.settled && pick.monochrome)
        Paper.monochrome = monochrome
    }

    /// Shots per frame is the only thing the operator picks; the rest is read
    /// from the captures. Used by the Settings menu after import.
    func setShotsPerFrame(_ three: Bool) {
        let mono = workspace
            .flatMap { Invert.monoCaptures(Self.captures(in: $0.captures)) }
            ?? (captureMode == .mono1 || captureMode == .mono3)
        let r = Invert.layoutAndFilm(threeShot: three, mono: mono)
        captureMode = r.layout
        // Only where the film type is SETTLED by the layout. It used to set
        // `true` and never clear it, so a roll wrongly imported as a single mono
        // capture stayed black and white after the mistake was corrected.
        if r.settled { monochrome = true }
        status = "Capture: \(r.layout.rawValue) — re-invert to apply"
    }

    /// The capture files in a folder. Same filter the inverter uses, in one place
    /// so the picker cannot disagree with what actually gets grouped.
    ///
    /// `nonisolated` because the panel accessory reads it while being built:
    /// FileManager is safe off the main actor, as `loadRecents` already relies on.
    nonisolated static func captures(in dir: URL) -> [URL] {
        let exts: Set<String> = ["tif", "tiff", "png"]
        return ((try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) && !Invert.isLCC($0) }
    }
}

/// The import panel's accessory view.
///
/// An NSObject so it can be its own target: the film popup has to REACT to the
/// capture popup, because "one shot per frame" from single-channel files can
/// only be black and white, and a control that offers a choice it then overrides
/// is worse than no control.
final class RollPicker: NSObject {
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 372, height: 64))
    private let capture = NSPopUpButton(frame: NSRect(x: 78, y: 34, width: 284, height: 26))
    private let film = NSPopUpButton(frame: NSRect(x: 78, y: 4, width: 284, height: 26))
    /// Read from the files, not chosen. Drives whether film type is still a
    /// question once shots-per-frame is known.
    private var monoFiles = false
    /// Did the operator actually pick, or is the popup just showing a default?
    /// `applyRollPicker` trusts the files over an untouched popup.
    private(set) var userChose = false

    var threeShot: Bool { capture.indexOfSelectedItem == 0 }
    var monochrome: Bool { film.indexOfSelectedItem == 1 }

    override init() {
        super.init()
        capture.addItems(withTitles: ["Trichromatic (RGB)", "Single shot"])
        capture.target = self
        capture.action = #selector(captureChanged)
        film.addItems(withTitles: ["Colour", "Black & white"])
        for (text, y) in [("Capture:", CGFloat(38)), ("Film:", CGFloat(8))] {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 4, y: y, width: 68, height: 18)
            l.alignment = .right
            box.addSubview(l)
        }
        box.addSubview(capture); box.addSubview(film)
    }

    /// The open roll's values, as the starting position before any folder is
    /// selected. Replaced by `reseed` the moment one is.
    func start(captureMode: Invert.Layout, monochrome: Bool) {
        capture.selectItem(at: captureMode == .mono1 || captureMode == .rgb1 ? 1 : 0)
        film.selectItem(at: monochrome ? 1 : 0)
        sync()
    }

    /// Seeded from the folder under the cursor, so the common cases need no
    /// interaction at all. Does NOT set `userChose`: this is a suggestion.
    private func reseed(_ folder: URL?) {
        guard let folder else { return }
        let caps = RollStore.captures(in: folder)
        monoFiles = Invert.monoCaptures(caps) ?? false
        if let s = Invert.suggestLayout(caps) {
            capture.selectItem(at: s.layout == .mono1 || s.layout == .rgb1 ? 1 : 0)
            film.selectItem(at: s.monochrome ? 1 : 0)
        }
        sync()
    }

    @objc private func captureChanged() {
        userChose = true
        sync()
    }

    /// Film type stops being a question when the capture is a single mono plane:
    /// one panchromatic channel can only be black and white. A control that
    /// offers a choice it then overrides is worse than no control.
    private func sync() {
        let settled = !threeShot && monoFiles          // i.e. mono1
        if settled { film.selectItem(at: 1) }
        film.isEnabled = !settled
        film.toolTip = settled
            ? "A single mono capture has no colour in it, so it can only be black and white."
            : nil
    }
}

extension RollPicker: NSOpenSavePanelDelegate {
    func panelSelectionDidChange(_ sender: Any?) {
        reseed((sender as? NSOpenPanel)?.url)
    }
}

/// Minilab operation is keyboard-driven — that is what makes it fast. A local
/// NSEvent monitor is more predictable here than scattering .onKeyPress across
/// views, and it keeps the mapping in one readable place.
@MainActor
func installKeyMonitor(_ store: RollStore) {
    // B held down shows the uncorrected frame. keyUp is monitored separately so
    // it behaves like a held button rather than a toggle.
    NSEvent.addLocalMonitorForEvents(matching: .keyUp) { ev in
        if ev.charactersIgnoringModifiers?.lowercased() == "b", store.showBefore {
            store.showBefore = false; return nil
        }
        return ev
    }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
        let shift = ev.modifierFlags.contains(.shift)
        if ev.modifierFlags.contains(.command),
           ev.charactersIgnoringModifiers?.lowercased() == "z" {
            shift ? store.redo() : store.undo(); return nil
        }
        if !ev.modifierFlags.contains(.command),
           ev.charactersIgnoringModifiers?.lowercased() == "b" {
            if !store.showBefore { store.showBefore = true }
            return nil
        }
        let big = shift ? 3 : 1
        // COMMAND KEYS BELONG TO THE MENU BAR. This switch reads
        // `charactersIgnoringModifiers`, so without this split every bare operator
        // key also swallowed its Command version -- a local monitor runs before
        // the responder chain, so returning nil meant the menu never saw it.
        // Measured broken this way: Cmd-N (eaten by reset density), Cmd-R (by
        // rotate), Cmd-H (by hold, so the app would not even hide) and Cmd-K (by
        // reset colour). Only the `b` case above had guarded against it, one case
        // at a time; this guards all of them at once.
        if ev.modifierFlags.contains(.command) {
            switch ev.charactersIgnoringModifiers?.lowercased() {
            case "c": store.copyEdit(); return nil
            case "v": store.pasteEdit(); return nil
            default: return ev             // hand every other Command key onward
            }
        }
        switch ev.charactersIgnoringModifiers?.lowercased() {
        case "7": store.bump(cyan: +big); return nil
        case "4": store.bump(cyan: -big); return nil
        case "8": store.bump(magenta: +big); return nil
        case "5": store.bump(magenta: -big); return nil
        case "9": store.bump(yellow: +big); return nil
        case "6": store.bump(yellow: -big); return nil
        case "n": store.resetDensity(); return nil
        case "k": store.resetColour(); return nil
        case "h": store.hold(); return nil
        case "r": shift ? store.rotateAll() : store.rotate(); return nil
        default: break
        }
        switch ev.keyCode {
        case 126: store.bump(density: +big); return nil     // up   = +D = darker
        case 125: store.bump(density: -big); return nil     // down = -D = lighter
        case 123: store.step(-1); return nil                // left
        case 124: store.step(+1); return nil                // right
        // F1..F6, the six the machine puts in the strip at bottom left. F2 and F3
        // were already Rotate / All Rotate, which is what the real F2 and F3 do;
        // the other four now match the strip this app draws.
        case 122: store.reinvert(selectedOnly: true); return nil           // F1
        case 120: shift ? store.rotateAll() : store.rotate(); return nil   // F2 rotate
        case 99:  store.rotateAll(); return nil             // F3 rotate roll
        case 118: store.copyEdit(); return nil              // F4
        case 96:  store.pasteEdit(); return nil             // F5
        case 97:  store.pasteAll(); return nil              // F6
        default: return ev
        }
    }
}
