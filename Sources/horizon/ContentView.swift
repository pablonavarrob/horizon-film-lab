import SwiftUI

// Teal header, white stage, chunky silver controls. No modals: every control is
// inline so the big preview reacts the moment you click it.

struct ContentView: View {
    @ObservedObject var store: RollStore
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store)
            if store.frames.isEmpty {
                // A real empty state. Previously this drew the film strip and
                // the controls panel as empty husks plus an 8px orphan box,
                // which read as a broken window rather than an idle one.
                EmptyState(store: store, dropping: dropping)
            } else {
                HStack(spacing: 6) {
                    VStack(spacing: 6) {
                        // DEV-REVIEW — the end-of-roll consistency pass. One big
                        // preview is for correcting ONE frame; judging whether a
                        // roll hangs together needs several at a size you can
                        // actually read, which 100px tiles are not.
                        if store.reviewGrid {
                            ReviewGrid(store: store)
                        } else {
                            Stage(store: store)
                            // Taller than before: the tile grew a marker row and
                            // two data rows, so the thumbnail needs the room back.
                            Strip(store: store).frame(height: 152)
                        }
                    }
                    Controls(store: store).frame(width: 348)
                }
                .padding(6)
            }
            BottomBar(store: store)
            StatusStrip(store: store)
        }
        .background(FUI.silver)
        .splash($store.showSplash)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in store.accept(url) }
            }
            return true
        }
    }
}

/// Idle window: say what to do, once, in plain language.
private struct EmptyState: View {
    @ObservedObject var store: RollStore
    let dropping: Bool

    var body: some View {
        ZStack {
            Color.white
            VStack(spacing: 18) {
                if let badge = FUI.badge {
                    Image(nsImage: badge).resizable().scaledToFit().frame(height: 92)
                }
                Text("Drop a folder of scans here")
                    .font(.custom("Tahoma", size: 20).weight(.bold))
                    .foregroundStyle(FUI.ink)
                Text("Raw captures get inverted and opened.\nAlready-inverted rolls just open.")
                    .font(FUI.label()).foregroundStyle(FUI.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("New Roll…") { store.newRoll() }
                        .buttonStyle(Chunky(height: 44, minWidth: 170, tint: FUI.green))
                    Button("Open Existing") { store.openPanel() }
                        .buttonStyle(Chunky(height: 44, minWidth: 150))
                }
                .padding(.top, 4)
                RecentRolls(store: store)               // DEV-RECENT
                if !store.status.isEmpty {
                    Text(store.status).font(FUI.small()).foregroundStyle(FUI.ink.opacity(0.65))
                }
            }
            .padding(40)
        }
        .overlay(Rectangle().strokeBorder(dropping ? FUI.green : .clear, lineWidth: 4))
        .bevel(up: false)
        .padding(6)
    }
}

private struct Header: View {
    @ObservedObject var store: RollStore
    var body: some View {
        HStack(spacing: 10) {
            if let badge = FUI.badge {
                Image(nsImage: badge).resizable().scaledToFit().frame(height: 30)
            }
            // Black text: it sits on the light half of the gradient.
            Text("Digital Image Export").font(FUI.label(true)).foregroundStyle(FUI.ink)
            Field(text: store.current?.name ?? "", width: 250, height: 21, readOnly: true)
            // The rounded count pill sits between the order field and the label
            // on every reference screen.
            Text("\(store.frames.count)")
                .font(FUI.label()).foregroundStyle(FUI.ink)
                .frame(width: 54, height: 19)
                .background(Capsule().fill(FUI.hex(0xBFBFBF)))
                .overlay(Capsule().strokeBorder(FUI.tealRule.opacity(0.55), lineWidth: 1))
            Text("Sheet(s)").font(FUI.label()).foregroundStyle(FUI.ink)
            Spacer()
            // The round glyph buttons in the top-right corner of every screen,
            // including the machine's red alert lamp -- which here lights when
            // something actually failed rather than being decorative.
            // Back to the idle window and its recent list. Left of Undo because
            // it is the only one of these that leaves the roll.
            RoundIcon(glyph: "⌂") { store.closeRoll() }
            RoundIcon(glyph: "↩") { store.undo() }
                .opacity(store.canUndo ? 1 : 0.45)
            RoundIcon(glyph: "?") { store.showSplash = true }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(LinearGradient(colors: [FUI.tealTop, FUI.tealBot],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(FUI.tealRule), alignment: .bottom)
    }
}

// MARK: - Stage

private struct Stage: View {
    @ObservedObject var store: RollStore
    var body: some View {
        ZStack {
            Color.white                       // white matte, like a lightbox
            if let f = store.current { StageImage(frame: f) }
            else { ProgressView().controlSize(.small) }
        }
        .bevel(up: false)
        .frame(minHeight: 300)
    }
}

/// DEV-SCOPE — observes the FRAME so both readouts follow every edit.
private struct ScopePanel: View {
    @ObservedObject var frame: FrameItem
    let mode: RollStore.ScopeMode
    var body: some View {
        Group {
            switch mode {
            case .histogram: Scope(scopes: frame.scopes)
            case .parade:    ParadeView(parade: frame.parade)
            }
        }
        .frame(height: 112)
    }
}

private struct StageImage: View {
    @ObservedObject var frame: FrameItem
    var body: some View {
        if let img = frame.image {
            Image(decorative: img, scale: 1).resizable().scaledToFit().padding(14)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Review grid

/// DEV-REVIEW — N frames at judgeable size, for the consistency pass.
///
/// THE ROWS ARE TRACKS. Each frame keeps its row for the whole roll, and the grid
/// slides ONE COLUMN at a time with every row moving together.
///
/// It was laid out row-major over a window that stepped by one frame, and the
/// motion was unreadable: advancing one frame pulled the leftmost tile of the
/// lower row up to the right-hand end of the upper one, so tiles jumped rows and
/// the eye lost every frame it was comparing.
///
/// Two things make it read: the layout is COLUMN-major, and the window start is
/// held to a multiple of the row count. Together those pin each frame to one row
/// permanently — with the start aligned, a frame's row is just its index modulo
/// the row count — so a step moves the whole grid sideways by one column and
/// nothing crosses rows. The cost is that reading order is down-then-across
/// rather than left-to-right, which is the price of stable rows.
///
/// Still a sliding window, not pages: a page would leave one frame stretched
/// across the whole grid at the end of a roll, the same fault `Strip` had.
///
/// The picture only, no data rows. This view answers "do these hang together?",
/// and per-frame numbers are what the strip and the panel are for — putting them
/// here just shrinks the pictures.
private struct ReviewGrid: View {
    @ObservedObject var store: RollStore

    /// 6 and 8 go two deep, 12 goes three, so tiles stay near the frame's shape.
    private var rows: Int { store.gridSize == 12 ? 3 : 2 }
    private var columns: Int { store.gridSize / rows }

    /// First frame on screen, always a multiple of `rows` — which is what pins
    /// each frame to one row, since an aligned start makes a frame's row simply
    /// its index modulo the row count.
    ///
    /// The upper bound is aligned UP, not down. Clamping to `n - k` and then
    /// aligning down loses the last frame whenever `n - k` is not a multiple of
    /// `rows`: a 37-frame roll two deep clamped to 31, aligned to 30, and showed
    /// frames 31–36 with frame 37 nowhere on screen. Rounding that bound up
    /// instead can leave one trailing blank cell, and that is the honest cost of
    /// stable rows — an odd roll cannot fill an even grid and keep every frame in
    /// a fixed row.
    private var start: Int {
        let n = store.frames.count, k = store.gridSize
        guard n > 0 else { return 0 }
        let maxStart = n > k ? (n - k + rows - 1) / rows * rows : 0
        let s = min(max(store.selected - (k - rows), 0), maxStart)
        return s - s % rows
    }

    var body: some View {
        let s = start, n = store.frames.count
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { c in
                        // Column-major: down the column, then across.
                        let i = s + c * rows + r
                        if i < n {
                            GridCell(frame: store.frames[i], index: i,
                                     selected: i == store.selected)
                                .onTapGesture { store.select(i) }
                        } else {
                            // Keeps the surviving tiles tile-shaped on a roll
                            // shorter than the grid, exactly as `Strip` does.
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(4)
        .background(FUI.panelWell)
        .bevel(up: false)
    }
}

private struct GridCell: View {
    @ObservedObject var frame: FrameItem
    let index: Int
    let selected: Bool

    var body: some View {
        ZStack {
            // White, like `Stage` — a lightbox, not a dark surround. Judging a
            // roll for consistency against a dark ground reads every frame as
            // brighter and more contrasty than it is.
            Color.white
            if let img = frame.image {
                Image(decorative: img, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
            }
            VStack {
                Spacer()
                HStack {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    if !frame.edit.isNeutral {
                        Text(frame.edit.stripSummary)
                            .font(.system(size: 9, design: .monospaced))
                    }
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().stroke(selected ? FUI.ring : .clear, lineWidth: 3))
    }
}

// MARK: - Six-up strip

private struct Strip: View {
    @ObservedObject var store: RollStore
    /// Six-up, SLIDING one frame at a time, selection at the right-hand end.
    ///
    ///   frames 1–6 selected   ->  1–6
    ///   frame 7               ->  2–7
    ///   frame 8               ->  3–8
    ///
    /// It used to page in strict blocks of six, which jumped the whole band every
    /// sixth frame and left the last page holding a single frame — and `Cell` has
    /// no fixed width, so that one tile stretched across the entire strip. Sliding
    /// keeps the window full, keeps five frames of context behind the selection,
    /// and puts the last frame in its own slot like every other.
    private var window: Range<Int> {
        let n = store.frames.count
        guard n > 0 else { return 0..<0 }
        let start = min(max(store.selected - 5, 0), max(n - 6, 0))
        return start..<min(start + 6, n)
    }
    var body: some View {
        HStack(spacing: 4) {
            ForEach(window, id: \.self) { i in
                Cell(frame: store.frames[i], index: i, selected: i == store.selected)
                    .onTapGesture { store.select(i) }
            }
            // A roll SHORTER than six still has to keep its tiles tile-sized, and
            // the clamp above cannot help there — there simply are not six frames.
            // Equal-share placeholders rather than one Spacer: `Cell` expands too,
            // so a lone Spacer would divide the band unevenly with it.
            ForEach(0..<(6 - window.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .padding(4)
        // The recessed column grey, so the tiles read as sitting IN a well
        // rather than floating on the same surface as the buttons.
        .background(FUI.panelWell)
        .bevel(up: false)
    }
}

/// The frame tile, rebuilt from the reference (sp500 p040 six-up, and p041 which
/// is one tile blown up). Three things it was missing:
///
///  - the small black ▲ centred ABOVE the image, the machine's frame marker
///  - the selected tile sits on a DARK surround, not just a coloured ring
///  - a two-row data block under the image: frame number and density on top,
///    then labelled C / M / Y / D fields. The old version crammed this into one
///    freeform summary string, which is the one thing no reference screen does.
///
/// The reference's six-up is a 3x2 grid, but that is a whole SCREEN you switch
/// to. This strip lives under a permanent preview, so it stays 1x6 -- a 3x2 grid
/// here would take half the stage. The tile internals are what carry the look.
private struct Cell: View {
    @ObservedObject var frame: FrameItem
    let index: Int
    let selected: Bool
    var body: some View {
        VStack(spacing: 1) {
            Text("▲").font(.system(size: 7))
                .foregroundStyle(selected ? FUI.ink : FUI.ink.opacity(0.45))
                .frame(height: 8)
            ZStack {
                Color.white
                if let img = frame.image {
                    // scaledToFit, not Fill: portrait scans in a landscape gate
                    // get cropped to slivers by Fill.
                    Image(decorative: img, scale: 1).resizable().scaledToFit().padding(2)
                }
            }
            .bevel(up: false, width: 1)
            .overlay(Rectangle().strokeBorder(selected ? FUI.ring : .clear, lineWidth: 2))
            // Row 1: frame number, then the frame's own density, right-aligned
            // the way every numeric readout on the machine is.
            HStack(spacing: 3) {
                Text("\(index + 1)").font(FUI.small(true)).foregroundStyle(FUI.ink)
                    .frame(width: 20, height: 13)
                    .background(FUI.fieldWhite).bevel(up: false, width: 1)
                if frame.edit.quarterTurns != 0 {
                    // Light on the selected tile: this label sits directly on the
                    // dark surround, where near-black ink is invisible.
                    Text("R\(frame.edit.quarterTurns * 90)").font(FUI.small())
                        .foregroundStyle(selected ? .white.opacity(0.9) : FUI.ink.opacity(0.7))
                }
                Spacer(minLength: 0)
                Text(frame.loaded ? String(format: "%.2f", frame.autoLight) : "—")
                    .font(FUI.small()).foregroundStyle(FUI.ink)
                    .frame(width: 34, height: 13, alignment: .trailing)
                    .padding(.trailing, 2)
                    .background(FUI.fieldRO).bevel(up: false, width: 1)
            }
            // Row 2: the correction keys, labelled, as on the real tile.
            HStack(spacing: 2) {
                key("C", frame.edit.cyan)
                key("M", frame.edit.magenta)
                key("Y", frame.edit.yellow)
                key("D", frame.edit.density)
                Spacer(minLength: 0)
            }
        }
        .padding(3)
        // The dark surround. p040 draws the selected tile on near-black while
        // the rest sit on the panel face.
        // Unselected tiles share the well's grey so only the selected one has a
        // surround, which is how p040 distinguishes them.
        .background(selected ? FUI.hex(0x3C3C3C) : FUI.panelWell)
        .frame(maxWidth: .infinity)
    }

    /// Label plus sunken value, the pattern the tile uses four times over. Blank
    /// rather than "0" when untouched: the machine leaves unset fields empty.
    private func key(_ name: String, _ v: Int) -> some View {
        HStack(spacing: 1) {
            Text(name).font(FUI.small())
                .foregroundStyle(selected ? .white.opacity(0.9) : FUI.ink.opacity(0.8))
            Text(v == 0 ? "" : "\(v > 0 ? "+" : "")\(v)")
                .font(FUI.small()).foregroundStyle(FUI.ink)
                .frame(width: 17, height: 12)
                .background(v == 0 ? FUI.fieldRO : FUI.lit)
                .bevel(up: false, width: 1)
        }
    }
}

// MARK: - Controls

private struct Controls: View {
    @ObservedObject var store: RollStore
    var body: some View {
        VStack(spacing: 10) {
            if let f = store.current {
                PanelHeading("Colour / Density")
                ColourKeys(store: store, frame: f)
                PanelHeading("Tone Adjustment")
                Gradation(store: store, frame: f)
                HStack(spacing: 5) {
                    Button("Rotate") { store.rotate() }.buttonStyle(Chunky(height: 32))
                    Button("Rotate All") { store.rotateAll() }.buttonStyle(Chunky(height: 32))
                }
                HStack(spacing: 5) {
                    Button("Re-invert") { store.reinvert(selectedOnly: true) }
                        .buttonStyle(Chunky(height: 32))
                    Button("Re-invert Roll") { store.reinvert(selectedOnly: false) }
                        .buttonStyle(Chunky(height: 32))
                }
                // DEV-SCOPE — the instruments, in the panel where instruments
                // belong. This lived over the picture for three revisions and was
                // wrong every time: a readout that occludes the thing it measures
                // is not a readout.
                Button {
                    store.showScopes.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(store.showScopes ? "▾" : "▸").font(FUI.small())
                        Text("Scopes").font(FUI.heading())
                        Spacer()
                    }
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(FUI.tealBar)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(FUI.ink)
                if store.showScopes {
                    // Pick one. Two in a 332 pt panel is two unreadable ones.
                    HStack(spacing: 4) {
                        ForEach(RollStore.ScopeMode.allCases, id: \.self) { m in
                            Button(m.label) { store.scopeMode = m }
                                .buttonStyle(Chunky(height: 22,
                                                    lit: store.scopeMode == m))
                        }
                    }
                    ScopePanel(frame: f, mode: store.scopeMode)
                }
                Spacer()
                Footnote(frame: f)
            } else { Spacer() }
        }
        .padding(8)
        .background(FUI.silver)
        .bevel(up: true)
    }
}

private struct ColourKeys: View {
    @ObservedObject var store: RollStore
    @ObservedObject var frame: FrameItem
    var body: some View {
        VStack(spacing: 6) {
            row("C", "Cyan", FUI.inkCyan, "Red", FUI.inkRed, FUI.barC,
                frame.edit.cyan) { store.bump(cyan: $0) }
            row("M", "Magenta", FUI.inkMagenta, "Green", FUI.inkGreen, FUI.barM,
                frame.edit.magenta) { store.bump(magenta: $0) }
            row("Y", "Yellow", FUI.inkYellow, "Blue", FUI.inkBlue, FUI.barY,
                frame.edit.yellow) { store.bump(yellow: $0) }
            row("D", "Darker", FUI.ink, "Lighter", FUI.ink, FUI.barD,
                frame.edit.density) { store.bump(density: $0) }
            HStack(spacing: 5) {
                Button("Reset Colour") { store.resetColour() }.buttonStyle(Chunky(height: 32))
                Button("Reset D") { store.resetDensity() }.buttonStyle(Chunky(height: 32))
            }
        }
    }
    /// The antagonist is on the minus button, so which way cyan goes is never
    /// something you have to remember.
    /// The word is tinted with the colour it moves towards, and the field wears
    /// the machine's own indicator bar underneath.
    private func row(_ k: String, _ plus: String, _ plusInk: Color,
                     _ minus: String, _ minusInk: Color, _ bar: Color, _ v: Int,
                     _ bump: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(k).font(FUI.value()).foregroundStyle(FUI.ink).frame(width: 18)
            Button { bump(-1) } label: {
                HStack(spacing: 3) {
                    Text("−").foregroundStyle(FUI.ink)
                    Text(minus).foregroundStyle(minusInk)
                }
            }.buttonStyle(Chunky())
            VStack(spacing: 0) {
                Field(text: Edit.keyLabel(v), width: 56, height: 28)
                Rectangle().fill(bar).frame(width: 56, height: 4)
                    .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.5), lineWidth: 1))
            }
            Button { bump(1) } label: {
                HStack(spacing: 3) {
                    Text("+").foregroundStyle(FUI.ink)
                    Text(plus).foregroundStyle(plusInk)
                }
            }.buttonStyle(Chunky())
        }
    }
}

/// Two independent axes. Highlight Soft and Shadow Hard can both be lit —
/// which is why this replaced the machine's seven mutually exclusive presets.
private struct Gradation: View {
    @ObservedObject var store: RollStore
    @ObservedObject var frame: FrameItem
    /// TWO independent axes: highlight and shadow, five steps each.
    ///
    /// This replaced a single mutually-exclusive list of seven presets, which is
    /// what the machine's own Tone Adjustment is. Two things were wrong with
    /// mirroring it here:
    ///
    ///  - the presets are pairs, so Highlight Hard + Shadow Soft -- compress the
    ///    top, open the bottom, an entirely ordinary thing to want -- could not
    ///    be asked for at all. Picking one deselected the other.
    ///  - the seven presets only ever emit +-1. `Edit.high` and `Edit.shadow`
    ///    have always been +-2, and `soft2`/`hard2` were reachable from the CLI
    ///    but from no button, so the panel could reach about HALF the contrast
    ///    the render already supported. Slope range 0.91..1.15 against the
    ///    0.82..1.30 that was sitting there.
    ///
    /// Nothing in the render changed for this; both fields were already
    /// independent. `ToneButton` stays for the CLI's `--tone` presets.
    /// Gradation Selection, in the machine's printed order.
    private static let grades: [(String, Int)] =
        [("Hard 2", 2), ("Hard 1", 1), ("Normal", 0),
         ("Soft 1", -1), ("Soft 2", -2), ("Soft 3", -3)]
    /// DEV-CURVE — the same six slots read as one progression, and the range moves
    /// up by a step: the shoulder makes the top live, so there is somewhere to go.
    /// Stored values keep their meaning, 0 is still Normal and +2 still Strong.
    private static let curveGrades: [(String, Int)] =
        [("Very Strong", 3), ("Strong", 2), ("Medium", 1),
         ("Normal", 0), ("Light", -1), ("Soft", -2)]

    var body: some View {
        VStack(spacing: 4) {
            axis("Highlight", frame.edit.high) { store.setHigh($0) }
            axis("Shadow", frame.edit.shadow) { store.setShadow($0) }
                .padding(.top, 7)
            PanelHeading("Contrast").padding(.top, 8)
            // Two rows of three: six buttons stacked would push the panel past
            // the window, and the machine shows them as one list anyway.
            let set = store.newCurve ? Self.curveGrades : Self.grades
            ForEach([Array(set[0..<3]), Array(set[3..<6])], id: \.first!.0) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.0) { g in
                        Button(g.0) { store.setGradation(g.1) }
                            .buttonStyle(Chunky(height: 28, lit: frame.edit.gradation == g.1))
                    }
                }
            }
        }
    }

    /// One contrast axis: caption, then the five grades as a radio row.
    private func axis(_ name: String, _ current: Paper.Grade,
                      _ set: @escaping (Paper.Grade) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(FUI.small(true)).foregroundStyle(FUI.ink.opacity(0.8))
                .padding(.leading, 2)
            HStack(spacing: 3) {
                ForEach(Paper.Grade.allCases) { g in
                    Button(g.title) { set(g) }
                        .buttonStyle(Chunky(height: 27, lit: current == g))
                }
            }
        }
    }
}

/// The print emulation is not a mode you can switch off — it IS the render, so
/// it is stated rather than offered. Same for the absence of auto colour: the
/// film base is the only colour reference, deliberately.
/// The per-frame chips. A separate view purely so it can observe the frame.
private struct FrameChips: View {
    @ObservedObject var frame: FrameItem
    var body: some View {
        Chip(text: frame.edit.isNeutral ? "no correction" : frame.edit.stripSummary)
        if let l = frame.levels {
            Chip(text: String(format: "levels %.3f–%.3f",
                              l.lo.reduce(0, +) / 3, l.hi.reduce(0, +) / 3))
        }
    }
}

private struct Footnote: View {
    @ObservedObject var frame: FrameItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Print: \(Paper.modelName)")
                .font(FUI.small()).foregroundStyle(FUI.ink.opacity(0.7))
            HStack(spacing: 8) {
                let l = frame.levels
                ForEach(Array(["R", "G", "B"].enumerated()), id: \.element) { i, n in
                    Text(l == nil ? "\(n) —"
                         : String(format: "%@ %.3f–%.3f", n, l!.lo[i], l!.hi[i]))
                        .font(FUI.small()).foregroundStyle(FUI.ink.opacity(0.55))
                }
            }
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @ObservedObject var store: RollStore
    var body: some View {
        HStack(spacing: 6) {
            // The F-key strip, bottom-left, as on every reference screen. These
            // six are the keys the app already answers to, so the strip is a
            // legend for real bindings rather than decoration.
            FKeyStrip(keys: [
                ("F1", "Re-invert", { store.reinvert(selectedOnly: true) }),
                ("F2", "Rotate", { store.rotate() }),
                ("F3", "All Rotate", { store.rotateAll() }),
                ("F4", "Copy", { store.copyEdit() }),
                ("F5", "Paste", store.clipboard == nil ? nil : { store.pasteEdit() }),
                ("F6", "Paste All", store.clipboard == nil ? nil : { store.pasteAll() }),
            ])
            Divider().frame(height: 26)
            Button("◀ Frame") { store.step(-1) }.buttonStyle(Chunky(height: 36, minWidth: 84))
            Button("Frame ▶") { store.step(1) }.buttonStyle(Chunky(height: 36, minWidth: 84))
            Divider().frame(height: 26)
            Button("Undo") { store.undo() }
                .buttonStyle(Chunky(height: 36, minWidth: 70)).disabled(!store.canUndo)
            // Press and hold, like a loupe: releasing always returns to the
            // corrected view, so it cannot be left on by accident.
            Button(store.showBefore ? "Before" : "After") { }
                .buttonStyle(Chunky(height: 36, minWidth: 84, lit: store.showBefore))
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !store.showBefore { store.showBefore = true } }
                    .onEnded { _ in store.showBefore = false })
            // Copy / Paste / Paste All used to be three more big buttons here.
            // They are F4/F5/F6 in the strip on the left now, which is where the
            // machine keeps them -- so this is three fewer controls, not three
            // more, and the row fits again.
            Spacer()
            Button("New Roll…") { store.newRoll() }.buttonStyle(Chunky(height: 36, minWidth: 92))
            Button("Open") { store.openPanel() }.buttonStyle(Chunky(height: 36, minWidth: 68))
            Button("Export Frame") { store.exportAll(selectedOnly: true) }
                .buttonStyle(Chunky(height: 36, minWidth: 110))
            Button("Export All") { store.exportAll() }
                .buttonStyle(StartButton(height: 36, minWidth: 128))
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(FUI.silver)
        .bevel(up: true)
    }
}

/// Dark charcoal strip of sunken chips along the bottom, as every reference
/// screen has. Also gives `status` a proper home instead of squatting in the
/// teal header, where the real machine never puts it.
private struct StatusStrip: View {
    @ObservedObject var store: RollStore
    var body: some View {
        HStack(spacing: 6) {
            Chip(text: store.frames.isEmpty ? "No roll"
                 : "\(store.selected + 1) / \(store.frames.count)")
            // Observing the FRAME, not the store. Reading store.current.<x> from
            // a view that only observes the store shows a stale value: an edit
            // publishes on the FrameItem, so the store never notifies. That is
            // why this read +0.487 while the panel read +0.460 on the same frame.
            if let f = store.current { FrameChips(frame: f) }
            Chip(text: Paper.modelName)
            Chip(text: "LCC: \(store.lccLabel)")
            Spacer()
            Chip(text: [store.wantTIFF ? "TIFF" : nil, store.wantJPEG ? "JPEG" : nil]
                    .compactMap { $0 }.joined(separator: " + ").isEmpty
                 ? "no format" : [store.wantTIFF ? "TIFF" : nil, store.wantJPEG ? "JPEG" : nil]
                    .compactMap { $0 }.joined(separator: " + "))
            if !store.status.isEmpty {
                Text(store.status).font(FUI.small()).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(FUI.statusBar)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(FUI.hex(0x8A8A8A)),
                 alignment: .top)
    }
}
