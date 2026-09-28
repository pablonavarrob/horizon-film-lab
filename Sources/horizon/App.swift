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
    @Published private(set) var loadError: String?

    private var master: Master?
    private var loadTask: Task<Master, Error>?
    private var loadGeneration = UUID()

    var name: String { FrameItem.stem(of: url) }

    /// The master stem: the filename with whichever inverter's suffix it carries
    /// stripped. Both this and `export` derived it with identical inline code.
    nonisolated static func stem(of url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.hasSuffix(".ntg") { return String(stem.dropLast(4)) }
        if stem.hasSuffix("_cineon") { return String(stem.dropLast(7)) }
        return stem
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
    func reload() async { dropMaster(); await loadIfNeeded() }

    func dropMaster() {
        cancelLoad(); master = nil; loaded = false; loadError = nil
    }

    func cancelLoad() {
        loadGeneration = UUID()
        loadTask?.cancel(); loadTask = nil
    }

    func colourInput() -> RollColourCorrection.Input? {
        master.map { .init(master: $0, edit: edit) }
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
        let generation = loadGeneration
        if loadTask == nil {
            let u = url, fr = statsGate
            loadTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let result = try Master.load(u, maxEdge: FrameItem.previewEdge, frame: fr)
                try Task.checkCancellation()
                return result
            }
        }
        guard let task = loadTask else { return }
        do {
            let result = try await task.value
            guard generation == loadGeneration, !Task.isCancelled else { return }
            master = result; loaded = true; loadError = nil; loadTask = nil
            redraw()
        } catch {
            guard generation == loadGeneration else { return }
            loadTask = nil; loaded = false
            if !(error is CancellationError) { loadError = error.localizedDescription }
        }
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
                            term: Master.Terminator, outputStem: String? = nil,
                            metadata: [String: Any] = [:]) throws {
        // DEV-GATE: statistics through the roll gate, crop through this frame's
        // own rectangle. Two different jobs, so two different rectangles.
        let full = try Master.load(url, maxEdge: nil, frame: gate,
                                   crop: cropToFrame ? fr : nil)
        let stem = outputStem ?? FrameItem.stem(of: url)
        if tiff { try full.write(edit, to: dir.appendingPathComponent(stem + ".tif"),
                                 as: .tiff, quality: 0.92, term, metadata: metadata) }
        if jpeg { try full.write(edit, to: dir.appendingPathComponent(stem + ".jpg"),
                                 as: .jpeg, quality: 0.92, term, metadata: metadata) }
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
    var metadata: URL { root.appendingPathComponent("metadata.json") }
    var borderDebug: URL { root.appendingPathComponent("debug/borders", isDirectory: true) }

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
    @Published private var persistenceWarnings: [String: String] = [:]
    var displayedStatus: String {
        let warning = persistenceWarnings.keys.sorted().compactMap { persistenceWarnings[$0] }.joined(separator: " · ")
        if !warning.isEmpty { return warning }
        if carrierMaskRequiresReinversion && !isProcessing {
            return status.isEmpty || status == Self.carrierReinversionMessage
                ? Self.carrierReinversionMessage : status + " · " + Self.carrierReinversionMessage
        }
        return status
    }
    @Published var rollMetadata = RollMetadata()
    /// New imports start with carrier handling on. The Settings toggle records
    /// this roll's choice; measurements change after a manual whole-roll rebuild.
    @Published private(set) var carrierMaskEnabled = true
    @Published private(set) var carrierMaskRequiresReinversion = false
    private var appliedCarrierMaskEnabled = false
    private static let carrierReinversionMessage =
        "Carrier change pending — choose Settings → Re-invert Whole Roll to apply."

    var canToggleCarrierMask: Bool {
        guard !isProcessing, !isPresentingDialog, !frames.isEmpty,
              let ws = workspace, Invert.loadSession(beside: ws.cache) != nil else { return false }
        return !Self.captures(in: ws.captures).isEmpty
    }

    var automaticCarrierDescription: String {
        guard let ws = workspace, !frames.isEmpty else { return "Open an imported roll to change carrier handling." }
        if isProcessing { return "Finish or cancel processing before changing carrier handling." }
        guard Invert.loadSession(beside: ws.cache) != nil,
              !Self.captures(in: ws.captures).isEmpty else {
            return "The original captures and a saved inversion are needed to change carrier handling."
        }
        if carrierMaskRequiresReinversion {
            return "Selected: \(carrierMaskEnabled ? "On" : "Off"); current cache: \(appliedCarrierMaskEnabled ? "On" : "Off"). Re-invert Whole Roll to apply."
        }
        return "On by default for new imports. This roll's choice is saved; changes require Re-invert Whole Roll. Debug images are generated on demand."
    }
    @Published private(set) var exporting = false
    @Published private(set) var isPresentingExport = false
    @Published private(set) var isPresentingMetadata = false
    @Published private(set) var isPresentingRoll = false
    var isPresentingDialog: Bool { isPresentingExport || isPresentingMetadata || isPresentingRoll }
    @Published private(set) var correctingColour = false
    @Published private(set) var diagnosingBorders = false
    var isProcessing: Bool { inverting || exporting || correctingColour || diagnosingBorders }
    var canExport: Bool {
        !frames.isEmpty && !isProcessing && !isPresentingDialog && !carrierMaskRequiresReinversion
    }
    var canEditRecentMetadata: Bool { !isProcessing && !isPresentingDialog }

    private var dialogParentWindow: NSWindow? {
        guard let app = NSApp, app.modalWindow == nil else { return nil }
        guard let window = app.mainWindow ?? app.keyWindow
            ?? app.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }),
              window.sheetParent == nil, window.attachedSheet == nil else { return nil }
        return window
    }

    func cancelProcessing() {
        inversionCancellation?.cancel()
        exportCancellation?.cancel()
        colourCancellation?.cancel()
        diagnosticCancellation?.cancel()
        status = "Cancelling processing…"
    }
    private var rollGeneration = UUID()
    private var editGeneration = UUID()
    private var loadRollTask: Task<Void, Never>?
    private var inversionCancellation: RollCancellation?
    private var exportCancellation: RollCancellation?
    private var colourCancellation: RollCancellation?
    private var diagnosticCancellation: RollCancellation?
    private var restoringRoll = false
    private var batchingEdits = false
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
    @Published var recents: [RecentRoll] = RollStore.loadRecentOrders()


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
        let before = idx.map { ($0, frames[$0].edit) }
        batchingEdits = true
        for i in idx {
            var e = frames[i].edit
            change(&e)
            frames[i].edit = e
        }
        batchingEdits = false
        guard before.contains(where: { frames[$0.0].edit != $0.1 }) else { return }
        undoStack.append(before)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        editGeneration = UUID()
        saveEdits()
    }

    func undo() {
        guard let step = undoStack.popLast() else { status = "nothing to undo"; return }
        let valid = step.filter { frames.indices.contains($0.index) }
        guard !valid.isEmpty else { return }
        redoStack.append(valid.map { ($0.index, frames[$0.index].edit) })
        batchingEdits = true
        for s in valid { frames[s.index].edit = s.edit }
        batchingEdits = false
        selected = valid[0].index
        editGeneration = UUID()
        if saveEdits() { status = valid.count == 1 ? "undo" : "undo — \(valid.count) frames" }
    }

    func redo() {
        guard let step = redoStack.popLast() else { status = "nothing to redo"; return }
        let valid = step.filter { frames.indices.contains($0.index) }
        guard !valid.isEmpty else { return }
        undoStack.append(valid.map { ($0.index, frames[$0.index].edit) })
        batchingEdits = true
        for s in valid { frames[s.index].edit = s.edit }
        batchingEdits = false
        selected = valid[0].index
        editGeneration = UUID()
        if saveEdits() { status = valid.count == 1 ? "redo" : "redo — \(valid.count) frames" }
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
    private var carrierRects: [String: Invert.Border] = [:]
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
        guard !restoringRoll else { return }
        guard !inverting else { return }
        guard let ws = workspace else { return }
        do {
            var session = try JSONDecoder().decode(Invert.Session.self, from: Data(contentsOf: ws.session))
            edit(&session)
            try RollPersistence.write(session, to: ws.session)
            persistenceWarnings.removeValue(forKey: "session")
        } catch {
            persistenceWarnings["session"] = "Could not save roll settings: \(error.localizedDescription)"
        }
    }



    /// Which print model renders the master. Empty = the built-in RA-4
    /// Archive simulation; otherwise the path to a .cube film-print LUT.
    @Published var printLUTPath: String = UserDefaults.standard.string(forKey: "printLUT") ?? "" {
        didSet {
            UserDefaults.standard.set(printLUTPath, forKey: "printLUT")
            applyPrintModel()
        }
    }

    /// Menu capabilities follow the transforms actually used by the renderer.
    /// A missing/rejected file path must not disable the built-in paper controls.
    /// ICC has the same precedence here as in Master.outLinear/render16.
    var usesICCPrintModel: Bool { Paper.outputICC != nil }
    var usesPrintLUT: Bool { Paper.outputICC == nil && Paper.printLUT != nil }
    var usesBuiltInPrintModel: Bool { Paper.outputICC == nil && Paper.printLUT == nil }

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
            // Clear the previous ICC so the selected LUT becomes the sole
            // print emulation, matching the renderer's ICC-first precedence.
            iccPath = ""
            printLUTPath = u.path
        }
    }

    // ============================== DEV-ICC ==============================
    /// External ICC print emulation, or an empty path for none. It replaces
    /// the built-in paper conversion after the exposure and colour adjustments.
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
        panel.allowedContentTypes = [.tiff, .png, .rawImage]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var files: [URL] = []
        for u in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                files += ((try? FileManager.default.contentsOfDirectory(at: u,
                            includingPropertiesForKeys: nil)) ?? [])
                    .filter { CaptureDecoder.isSupported($0) }
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
        guard !isPresentingDialog else { status = "Close the current dialog first"; return }
        guard !inverting, !diagnosingBorders else { status = "Finish or cancel the current processing first"; return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            status = "This folder is no longer available"; return
        }
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        let ws = Workspace(anyOf: dir)
        let captures = Self.captures(in: ws.captures)
        if ws.hasMasters && (captures.isEmpty || CacheManifest.status(captures: ws.captures, cache: ws.cache) == .complete) {
            open(ws); recordRecent(ws.captures); return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: ws.captures, includingPropertiesForKeys: nil)) ?? []
        if files.contains(where: { $0.lastPathComponent.hasSuffix(".ntg.tif") ||
                                   $0.lastPathComponent.hasSuffix("_cineon.tif") ||
                                   $0.lastPathComponent.hasSuffix("_cineon.tiff") }) {
            guard closeRoll() else { return }
            openLoose(ws.captures); recordRecent(ws.captures); return
        }
        guard !captures.isEmpty else { status = "Nothing to open in \(ws.captures.lastPathComponent)"; return }
        newRoll(ws.captures)
    }

    @discardableResult
    func closeRoll() -> Bool {
        guard !isPresentingDialog else { status = "Close the current dialog first"; return false }
        guard saveEdits() else { return false }
        rollGeneration = UUID(); editGeneration = UUID()
        loadRollTask?.cancel(); loadRollTask = nil
        inversionCancellation?.cancel(); exportCancellation?.cancel(); colourCancellation?.cancel()
        diagnosticCancellation?.cancel()
        for frame in frames { frame.cancelLoad() }
        showBefore = false
        undoStack.removeAll(); redoStack.removeAll()
        frames = []; selected = 0; workspace = nil
        frameRects = [:]; carrierRects = [:]
        persistenceWarnings.removeAll()
        restoringRoll = true
        captureMode = .rgb3; monochrome = false; carrierMaskEnabled = true
        appliedCarrierMaskEnabled = false; carrierMaskRequiresReinversion = false
        rollMetadata = RollMetadata()
        restoringRoll = false
        status = inverting ? "Cancelling processing…" : "Roll closed"
        return true
    }

    func open(_ ws: Workspace) {
        guard closeRoll() else { return }
        workspace = ws
        restoringRoll = true
        let session = Invert.loadSession(beside: ws.cache)
        frameRects = session?.frameBorders ?? [:]
        carrierRects = session?.carrierBorders ?? [:]
        captureMode = session.flatMap { Invert.Layout(rawValue: $0.layout) } ?? .rgb3
        monochrome = session?.monochrome ?? false
        appliedCarrierMaskEnabled = session?.carrierMaskEnabled ?? false
        carrierMaskEnabled = session?.pendingCarrierMaskEnabled ?? appliedCarrierMaskEnabled
        carrierMaskRequiresReinversion = session?.pendingCarrierMaskEnabled != nil
        lccPaths = session?.lcc ?? []
        do { rollMetadata = try RollPersistence.loadMetadata(from: ws.metadata) }
        catch { persistenceWarnings["metadata"] = "Photographic metadata is unreadable — the file has been preserved" }
        if rollMetadata.title.isEmpty { rollMetadata.title = ws.captures.lastPathComponent }
        restoringRoll = false
        openLoose(ws.cache, keepWorkspace: true)
    }

    func editRollDetails() {
        guard !isPresentingDialog else { return }
        guard !isProcessing, let ws = workspace else { status = "Open a roll and finish processing first"; return }
        guard let parent = dialogParentWindow else { return }
        let generation = rollGeneration
        isPresentingRoll = true
        Task { @MainActor in
            let choice = await RollDialogs.presentRollSettings(folder: ws.captures,
                captureCount: Self.captures(in: ws.captures).count, suggestedLayout: captureMode,
                suggestedMonochrome: monochrome, metadata: rollMetadata, for: parent)
            isPresentingRoll = false
            guard generation == rollGeneration, let choice else { return }
            applyRollSettings(choice, to: ws)
        }
    }

    private func applyRollSettings(_ choice: RollImportOptions, to ws: Workspace) {
        do {
            try RollPersistence.saveMetadata(choice.metadata, to: ws.metadata)
            persistenceWarnings.removeValue(forKey: "metadata")
        }
        catch { persistenceWarnings["metadata"] = "Could not save roll metadata: \(error.localizedDescription)"; return }
        let captureChanged = captureMode != choice.layout
        rollMetadata = choice.metadata
        refreshRecents()
        captureMode = choice.layout; monochrome = choice.monochrome
        status = captureChanged ? "Roll details saved — re-invert to apply capture changes" : "Roll details saved"
    }

    /// Edit a recent order without opening its images or changing the active roll.
    func editRecentMetadata(_ folder: URL) {
        guard canEditRecentMetadata else { return }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow,
              parent.sheetParent == nil, parent.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        let target = Workspace(anyOf: folder)
        let metadata: RollMetadata
        do { metadata = try RollPersistence.loadMetadata(from: target.metadata) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Roll metadata could not be opened"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            isPresentingMetadata = true
            alert.beginSheetModal(for: parent) { [weak self] _ in
                self?.isPresentingMetadata = false
            }
            return
        }
        isPresentingMetadata = true
        Task { @MainActor in
            defer { isPresentingMetadata = false }
            await RollDialogs.presentMetadata(folder: target.captures, metadata: metadata,
                                               for: parent) { updated in
                try self.saveRecentMetadata(updated, for: target.captures)
            }
        }
    }

    /// Persist photographic details only. Cache, inversion settings and edits
    /// are deliberately outside this operation, including for legacy workspaces.
    func saveRecentMetadata(_ metadata: RollMetadata, for folder: URL) throws {
        let target = Workspace(anyOf: folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.captures.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Err("This roll folder is no longer available.") }
        try RollPersistence.saveMetadata(metadata, to: target.metadata)
        if workspace?.captures.standardizedFileURL.resolvingSymlinksInPath().path
            == target.captures.standardizedFileURL.resolvingSymlinksInPath().path {
            rollMetadata = metadata
            persistenceWarnings.removeValue(forKey: "metadata")
        }
        refreshRecents()
        status = "Roll metadata saved"
    }

    /// `edits.json` lives in the workspace beside the RAW CAPTURES, one per roll,
    /// holding every frame's corrections. A few hundred bytes, and it survives
    /// deleting the 1.9 GB cache.
    private func loadEdits() {
        guard let ws = workspace, FileManager.default.fileExists(atPath: ws.edits.path) else { return }
        do {
            let map = try JSONDecoder().decode([String: Edit].self, from: Data(contentsOf: ws.edits))
            batchingEdits = true
            for frame in frames { if let edit = map[frame.name] { frame.edit = edit } }
            batchingEdits = false
            persistenceWarnings.removeValue(forKey: "edits")
        } catch { persistenceWarnings["edits"] = "edits.json is unreadable — preserved for recovery" }
    }

    @discardableResult
    func saveEdits() -> Bool {
        guard !batchingEdits, !restoringRoll, let ws = workspace else { return true }
        do {
            var map: [String: Edit] = [:]
            if FileManager.default.fileExists(atPath: ws.edits.path) {
                map = try JSONDecoder().decode([String: Edit].self, from: Data(contentsOf: ws.edits))
            }
            for frame in frames {
                if frame.edit.isNeutral { map.removeValue(forKey: frame.name) }
                else { map[frame.name] = frame.edit }
            }
            if map.isEmpty && !FileManager.default.fileExists(atPath: ws.edits.path) { return true }
            try RollPersistence.write(map, to: ws.edits)
            persistenceWarnings.removeValue(forKey: "edits")
            return true
        } catch {
            persistenceWarnings["edits"] = "Could not save edits; existing file preserved: \(error.localizedDescription)"
            return false
        }
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
            let ws = Workspace(anyOf: dir)
            workspace = ws
            captureMode = .rgb3
            monochrome = false
            Paper.monochrome = false
            do { rollMetadata = try RollPersistence.loadMetadata(from: ws.metadata) }
            catch { persistenceWarnings["metadata"] = "Photographic metadata is unreadable — the file has been preserved" }
            if rollMetadata.title.isEmpty { rollMetadata.title = ws.captures.lastPathComponent }
        }
        loadRollTask?.cancel()
        for frame in frames { frame.cancelLoad() }
        undoStack.removeAll(); redoStack.removeAll()
        let expected = CacheManifest.read(cache: dir).map { Set($0.expected) }
        frames = urls.filter { expected?.contains(FrameItem.stem(of: $0)) ?? true }.map(FrameItem.init)
        // DEV-GATE: the detector gate always, plus the pooled-profile one when
        // the flag is on. Union, so it can only ever exclude more.
        let detector = Invert.Border.gate(of: frameRects)
        let gate = detector
        for f in frames {
            f.onEdit = { [weak self] in
                guard let self, !self.batchingEdits else { return }
                self.editGeneration = UUID(); self.saveEdits()
            }
            f.frameRect = frameRects[f.name]
            f.statsGate = statisticsGate(for: f.name, base: gate)
        }
        selected = 0
        status = "\(frames.count) frames ready"
        loadEdits()
        loadRollTask = Task { await loadAll() }
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
    private func statisticsGate(for name: String, base: Invert.Border? = nil) -> Invert.Border {
        let gate = base ?? Invert.Border.gate(of: frameRects)
        guard appliedCarrierMaskEnabled, let extra = carrierRects[name] else { return gate }
        return .init(left: max(gate.left, extra.left), top: max(gate.top, extra.top),
                     right: max(gate.right, extra.right), bottom: max(gate.bottom, extra.bottom))
    }

    private func loadAll() async {
        let generation = rollGeneration
        let order = frames.indices.contains(selected) ? [selected] + frames.indices.filter { $0 != selected } : Array(frames.indices)
        let items = order.map { frames[$0] }
        var loaded = 0, cursor = 0
        await withTaskGroup(of: Void.self) { group in
            while cursor < items.count, cursor < 3 {
                let frame = items[cursor]; cursor += 1
                group.addTask { await frame.loadIfNeeded() }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, generation == rollGeneration else { group.cancelAll(); return }
                loaded += 1
                status = "reading \(loaded) of \(items.count)…"
                if cursor < items.count {
                    let frame = items[cursor]; cursor += 1
                    group.addTask { await frame.loadIfNeeded() }
                }
            }
        }
        guard !Task.isCancelled, generation == rollGeneration else { return }
        let failed = items.filter { !$0.loaded }.count
        status = failed == 0 ? "\(frames.count) frames ready" : "\(failed) frames could not load — select a frame to retry"
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
    func resetColour() { mutate { $0.cyan = 0; $0.magenta = 0; $0.yellow = 0; $0.autoCyan = 0; $0.autoMagenta = 0; $0.autoYellow = 0 } }
    func resetDensity() { mutate { $0.density = 0 } }
    func setHigh(_ g: Paper.Grade) { mutate { $0.high = g } }
    func setShadow(_ g: Paper.Grade) { mutate { $0.shadow = g } }
    /// Gradation Selection, -3...+2 = Soft3...Hard2.
    func setGradation(_ g: Int) {
        mutate { $0.gradation = min(max(g, Paper.gradationRange.0),
                                    Paper.gradationRange.1) }
    }

    // ============================== DEV-CURVE ==============================
    /// The shouldered curve is the standard default. Its older contrast behavior
    /// remains available as a regular Curve preference.
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

    @Published var newCurve: Bool =
        (UserDefaults.standard.object(forKey: "newCurve") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(newCurve, forKey: "newCurve")
            Paper.newCurve = newCurve
            // Redraw with the chosen curve; toneSlopes limits the legacy range
            // without rewriting the frame's saved contrast adjustment.
            for f in frames { f.refresh() }
            status = newCurve ? "Contrast: shouldered curve, DRANGE = range only"
                              : "Contrast: legacy curve"
        }
    }
    // =======================================================================
    func correctRollColour() {
        guard !carrierMaskRequiresReinversion else { status = Self.carrierReinversionMessage; return }
        guard !isProcessing, !frames.isEmpty else { status = "Open a roll and finish processing first"; return }
        guard !monochrome else { status = "Colour correction is unavailable for black-and-white film"; return }
        let generation = rollGeneration, edits = editGeneration, cancellation = RollCancellation()
        colourCancellation = cancellation; correctingColour = true
        let items = frames
        status = "Preparing roll colour samples…"
        Task {
            for frame in items {
                if cancellation.isCancelled { break }
                await frame.loadIfNeeded()
            }
            guard !cancellation.isCancelled, generation == rollGeneration else {
                if colourCancellation === cancellation { correctingColour = false }; return
            }
            guard edits == editGeneration, items.allSatisfy({ $0.loaded }) else {
                correctingColour = false; status = "Finish loading and editing, then run colour correction again"; return
            }
            let input = items.compactMap { $0.colourInput() }, term = Master.Terminator.current
            let signature = renderSignature
            status = "Correcting roll colour…"
            let result = await Task.detached(priority: .userInitiated) {
                RollColourCorrection.estimate(input, term: term, cancelled: { cancellation.isCancelled })
            }.value
            guard colourCancellation === cancellation else { return }
            correctingColour = false
            guard !cancellation.isCancelled, generation == rollGeneration,
                  edits == editGeneration, signature == renderSignature else {
                if generation == rollGeneration { status = "The roll changed; run colour correction again" }; return
            }
            guard let result else { status = "Not enough consistent neutral evidence — colour unchanged"; return }
            mutate(Array(frames.indices)) {
                $0.autoCyan = result.cyan; $0.autoMagenta = result.magenta; $0.autoYellow = result.yellow
            }
            status = String(format: "Roll colour C%+.1f M%+.1f Y%+.1f — %d frames, %.0f%% evidence · Undo to revert",
                            result.cyan, result.magenta, result.yellow, result.frames, result.fraction * 100)
        }
    }

    private var renderSignature: String {
        "\(iccPath)|\(printLUTPath)|\(monochrome)|\(newCurve)|\(highlightRolloff)|\(printContrast)"
    }

    func toggleCarrierMask() {
        guard canToggleCarrierMask, let ws = workspace else {
            status = automaticCarrierDescription; return
        }
        do {
            var session = try JSONDecoder().decode(Invert.Session.self,
                                                    from: Data(contentsOf: ws.session))
            let requested = !carrierMaskEnabled
            let needsRebuild = requested != session.carrierMaskEnabled
                || CacheManifest.status(captures: ws.captures, cache: ws.cache) != .complete
            session.pendingCarrierMaskEnabled = needsRebuild ? requested : nil
            try RollPersistence.write(session, to: ws.session)
            carrierMaskEnabled = requested
            carrierMaskRequiresReinversion = needsRebuild
            persistenceWarnings.removeValue(forKey: "session")
            status = needsRebuild ? Self.carrierReinversionMessage : "Pending carrier change cleared"
            RollStore.onRollProps?()
        } catch {
            persistenceWarnings["session"] = "Could not save carrier setting: \(error.localizedDescription)"
        }
    }

    var hasBorderDebugImages: Bool {
        guard let folder = workspace?.borderDebug,
              let reports = try? FileManager.default.contentsOfDirectory(at: folder,
                  includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return false }
        return reports.contains { $0.lastPathComponent.hasPrefix("border-debug-") }
    }

    func showBorderDebugImages() {
        guard let folder = workspace?.borderDebug, hasBorderDebugImages else {
            status = "Choose Settings → Generate Border Debug Images first"; return
        }
        NSWorkspace.shared.open(folder)
    }

    /// Rerun detection for inspection without changing the applied measurements.
    func generateBorderDebugImages() {
        guard !isProcessing, let ws = workspace else {
            status = "Open a roll and finish processing first"; return
        }
        let generation = rollGeneration, layout = captureMode, cancellation = RollCancellation()
        diagnosticCancellation = cancellation; diagnosingBorders = true
        status = "Analyzing borders and repeated carrier geometry…"
        RollStore.onRollProps?()
        Task.detached(priority: .userInitiated) {
            do {
                let report = try Invert.writeBorderDiagnostics(dir: ws.captures, layout: layout,
                    out: ws.cache, destination: ws.borderDebug,
                    cancellation: { cancellation.isCancelled },
                    progress: { message in
                        Task { @MainActor in
                            if generation == self.rollGeneration,
                               self.diagnosticCancellation === cancellation,
                               !cancellation.isCancelled { self.status = message }
                        }
                    })
                await MainActor.run {
                    guard self.diagnosticCancellation === cancellation else { return }
                    self.diagnosingBorders = false; self.diagnosticCancellation = nil
                    RollStore.onRollProps?()
                    guard generation == self.rollGeneration, !cancellation.isCancelled else { return }
                    self.status = report.summary
                    if !NSWorkspace.shared.open(report.preview) {
                        NSWorkspace.shared.activateFileViewerSelecting([report.preview])
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.diagnosticCancellation === cancellation else { return }
                    self.diagnosingBorders = false; self.diagnosticCancellation = nil
                    RollStore.onRollProps?()
                    guard generation == self.rollGeneration else { return }
                    self.status = cancellation.isCancelled ? "Border analysis cancelled"
                        : "Border analysis stopped: \(error.localizedDescription)"
                }
            }
        }
    }

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
        guard !isPresentingDialog else { return }
        guard !carrierMaskRequiresReinversion else { status = Self.carrierReinversionMessage; return }
        guard !isProcessing else { status = "Finish current processing first"; return }
        let chosen = selectedOnly ? (current.map { [$0] } ?? []) : frames
        guard !chosen.isEmpty else { status = "Nothing to export"; return }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow,
              parent.sheetParent == nil, parent.attachedSheet == nil,
              NSApp.modalWindow == nil else {
            status = "Close the current dialog before exporting"; return
        }
        let names = chosen.map { $0.name + ".tif" }
        let generation = rollGeneration, metadata = rollMetadata
        let numbers = selectedOnly ? [selected + 1] : nil
        isPresentingExport = true
        // Leave the SwiftUI button action before displaying either sheet. A
        // nested runModal here blocks the UI updates made by export controls.
        Task { @MainActor in
            let request = await RollDialogs.presentExport(metadata: metadata, originalNames: names,
                wantTIFF: wantTIFF, wantJPEG: wantJPEG, cropExport: cropExport,
                frameNumbers: numbers, for: parent)
            isPresentingExport = false
            guard generation == rollGeneration, let request else { return }
            guard !isProcessing, !carrierMaskRequiresReinversion else {
                status = "The roll changed while choosing export options; open Export again"; return
            }
            startExport(request, frames: chosen, originalNames: names)
        }
    }

    private func startExport(_ request: ExportRequest, frames chosen: [FrameItem],
                             originalNames names: [String]) {
        let dir: URL
        do { dir = try request.prepareDestination(originalNames: names) }
        catch { status = error.localizedDescription; return }
        wantTIFF = request.wantTIFF; wantJPEG = request.wantJPEG; cropExport = request.cropExport
        let jobs = chosen.enumerated().map { index, frame in
            (frame, frame.edit, frame.frameRect, frame.statsGate,
             request.stem(for: request.frameNumber(at: index), originalName: names[index]))
        }
        let term = Master.Terminator.current, metadata = request.metadata.imageProperties
        let generation = rollGeneration, cancellation = RollCancellation()
        exportCancellation = cancellation; exporting = true
        status = "exporting 0/\(jobs.count)…"
        Task.detached(priority: .userInitiated) {
            do {
                for (index, job) in jobs.enumerated() {
                    if cancellation.isCancelled { throw CancellationError() }
                    try job.0.export(job.1, frame: job.2, gate: job.3, to: dir,
                        tiff: request.wantTIFF, jpeg: request.wantJPEG, cropToFrame: request.cropExport,
                        term: term, outputStem: job.4, metadata: metadata)
                    await MainActor.run {
                        if generation == self.rollGeneration { self.status = "exporting \(index + 1)/\(jobs.count)…" }
                    }
                }
                await MainActor.run {
                    self.exporting = false
                    if generation == self.rollGeneration { self.status = "exported \(jobs.count) frames to \(dir.lastPathComponent)" }
                }
            } catch {
                await MainActor.run {
                    self.exporting = false
                    if generation == self.rollGeneration { self.status = "Export stopped: \(error.localizedDescription)" }
                }
            }
        }
    }

    func newRoll(_ folder: URL? = nil) {
        guard !isPresentingDialog else { status = "Close the current dialog first"; return }
        guard !isProcessing else { status = "Finish current processing first"; return }
        guard let parent = dialogParentWindow else { return }
        let generation = rollGeneration
        isPresentingRoll = true
        Task { @MainActor in
            defer { isPresentingRoll = false }
            let dir: URL
            if let folder { dir = folder } else {
                let chooser = NSOpenPanel()
                chooser.canChooseDirectories = true
                chooser.canChooseFiles = false
                chooser.prompt = "Choose roll"
                let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                    chooser.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
                }
                chooser.orderOut(nil)
                guard response == .OK, let url = chooser.url else { return }
                dir = url
            }
            let ws = Workspace(anyOf: dir), urls = Self.captures(in: dir)
            guard !urls.isEmpty else { status = "No supported captures found"; return }
            let saved = Invert.loadSession(beside: ws.cache), suggestion = Invert.suggestLayout(urls)
            let metadata: RollMetadata
            do { metadata = try RollPersistence.loadMetadata(from: ws.metadata) }
            catch { status = "Roll metadata cannot be read; metadata.json has been preserved"; return }
            guard let choice = await RollDialogs.presentImport(folder: dir, captureCount: urls.count,
                suggestedLayout: saved.flatMap { Invert.Layout(rawValue: $0.layout) } ?? suggestion?.layout ?? .rgb1,
                suggestedMonochrome: saved?.monochrome ?? suggestion?.monochrome ?? false,
                metadata: metadata, for: parent), generation == rollGeneration else { return }
            guard !Invert.group(urls, layout: choice.layout).isEmpty else {
                status = Invert.groupIssue ?? "Captures cannot be grouped with this mode"; return
            }
            guard saveEdits() else { return }
            do { try RollPersistence.saveMetadata(choice.metadata, to: ws.metadata) }
            catch { status = "Could not save roll metadata: \(error.localizedDescription)"; return }
            // End the dialog guard before intentionally replacing the active roll.
            isPresentingRoll = false
            guard closeRoll() else { return }
            restoringRoll = true
            captureMode = choice.layout; monochrome = choice.monochrome
            rollMetadata = choice.metadata
            restoringRoll = false
            let flats = saved.map { $0.lcc.map { URL(fileURLWithPath: $0) } } ?? lccURLs
            startInversion(ws, layout: choice.layout, monochrome: choice.monochrome,
                           carrier: true, lcc: flats, only: nil)
        }
    }

    func reinvert(selectedOnly: Bool) {
        guard !isProcessing, let ws = workspace else { status = "Open a roll and finish processing first"; return }
        guard !selectedOnly || !carrierMaskRequiresReinversion else {
            status = Self.carrierReinversionMessage; return
        }
        let only: Set<String>? = selectedOnly ? current.map { Set([$0.name]) } : nil
        if selectedOnly && only == nil { return }
        guard saveEdits() else { return }
        // A selected-frame rebuild keeps the existing roll's measurement recipe.
        // A manually requested whole-roll rebuild applies this roll's choice.
        startInversion(ws, layout: captureMode, monochrome: monochrome,
                       carrier: selectedOnly ? appliedCarrierMaskEnabled : carrierMaskEnabled,
                       lcc: lccURLs, only: only, forceRebuild: !selectedOnly)
    }

    private func startInversion(_ ws: Workspace, layout: Invert.Layout, monochrome: Bool,
                                carrier: Bool, lcc: [URL], only: Set<String>?, forceRebuild: Bool = false) {
        let generation = rollGeneration, cancellation = RollCancellation(), keepSelection = selected
        inversionCancellation = cancellation; inverting = true
        loadRollTask?.cancel()
        for frame in frames { frame.cancelLoad() }
        status = "Processing captures…"
        Task.detached(priority: .userInitiated) {
            do {
                try ws.makeDirs()
                try Invert.run(dir: ws.captures, layout: layout, perFrameBase: true,
                    out: ws.cache, only: only, forceRebuild: forceRebuild, lcc: lcc, monochrome: monochrome,
                    carrierMaskEnabled: carrier,
                    cancellation: { cancellation.isCancelled },
                    progress: { message in
                        Task { @MainActor in
                            if generation == self.rollGeneration, !cancellation.isCancelled { self.status = message }
                        }
                    })
                await MainActor.run {
                    self.inverting = false
                    guard generation == self.rollGeneration, !cancellation.isCancelled else { return }
                    self.open(ws)
                    self.selected = min(keepSelection, max(self.frames.count - 1, 0))
                    self.recordRecent(ws.captures)
                }
            } catch {
                await MainActor.run {
                    self.inverting = false
                    if generation == self.rollGeneration {
                        let session = Invert.loadSession(beside: ws.cache)
                        if let pending = session?.pendingCarrierMaskEnabled {
                            self.carrierMaskEnabled = pending
                        }
                        if session?.pendingCarrierMaskEnabled != nil
                            || CacheManifest.status(captures: ws.captures, cache: ws.cache) != .complete {
                            self.carrierMaskRequiresReinversion = true
                        }
                        self.status = cancellation.isCancelled ? "Processing cancelled" : "Processing stopped: \(error.localizedDescription)"
                        self.loadRollTask = Task { await self.loadAll() }
                    }
                }
            }
        }
    }

    func openPanel() {
        guard !isPresentingDialog else { status = "Close the current dialog first"; return }
        guard !isProcessing else { status = "Finish current processing first"; return }
        guard let parent = dialogParentWindow else { return }
        isPresentingRoll = true
        Task { @MainActor in
            let chooser = NSOpenPanel()
            chooser.canChooseDirectories = true
            chooser.canChooseFiles = false
            chooser.prompt = "Open roll"
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                chooser.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
            }
            chooser.orderOut(nil)
            isPresentingRoll = false
            if response == .OK, let url = chooser.url { accept(url) }
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
        let exts = CaptureDecoder.supportedExtensions
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
        if store.isPresentingDialog || NSApp.modalWindow != nil
            || NSApp.keyWindow?.sheetParent != nil || NSApp.mainWindow?.attachedSheet != nil
            || NSApp.keyWindow?.firstResponder is NSTextView { return ev }
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
