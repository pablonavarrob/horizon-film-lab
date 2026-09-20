import AppKit
import SwiftUI

// Explicit AppKit bootstrap, deliberately not `@main struct App: SwiftUI.App`.
//
// Two failed approaches, recorded so nobody repeats them:
//  1. top-level code calling `HorizonApp.main()` -- the process runs and the
//     app becomes frontmost, but the SwiftUI lifecycle is never installed and
//     no window is ever created.
//  2. `@main` on the App with the CLI handled in `init()` -- same result;
//     touching `NSApplication.shared` that early appears to interfere with
//     SwiftUI's own startup.
// Hosting the SwiftUI view in an NSWindow ourselves is boring and predictable.

if runCLI() { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)

/// Clicking the dock icon with no visible window has to bring the window back.
/// Without this the window is merely ORDERED OUT when you close it -- it still
/// exists, holding the whole roll -- and the click does nothing at all, which
/// reads as the app being hung. `applicationShouldTerminateAfterLastWindowClosed`
/// stays false on purpose so closing the window keeps the session and its
/// undo history alive.
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ a: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let w = window {
            w.makeKeyAndOrderFront(nil)
            a.activate(ignoringOtherApps: true)
        }
        return true
    }
}
let delegate = Delegate()
app.delegate = delegate

let store = MainActor.assumeIsolated { RollStore() }
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
window.title = "Horizon — Digital Image Export"
window.contentView = NSHostingView(rootView: ContentView(store: store))
window.center()
window.makeKeyAndOrderFront(nil)
delegate.window = window

// Menu bar. Export format lives in Settings here rather than in the window,
// so the panel stays about correcting the picture.
final class AppActions: NSObject {
    let store: RollStore
    init(store: RollStore) { self.store = store }
    @MainActor @objc func undo() { store.undo() }
    @MainActor @objc func redo() { store.redo() }
    @MainActor @objc func newRoll() { store.newRoll() }
    @MainActor @objc func openRoll() { store.openPanel() }
    @MainActor @objc func closeRoll() { store.closeRoll() }
    /// DEV-RECENT
    @MainActor @objc func openRecent(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        store.accept(u)
    }
    @MainActor @objc func exportSelected() { store.exportAll(selectedOnly: true) }
    @MainActor @objc func exportAll() { store.exportAll() }
    @MainActor @objc func toggleTIFF(_ item: NSMenuItem) {
        store.wantTIFF.toggle(); item.state = store.wantTIFF ? .on : .off
    }
    @MainActor @objc func toggleJPEG(_ item: NSMenuItem) {
        store.wantJPEG.toggle(); item.state = store.wantJPEG ? .on : .off
    }
    @MainActor @objc func toggleCropExport(_ item: NSMenuItem) {
        store.cropExport.toggle(); item.state = store.cropExport ? .on : .off
    }
    /// DEV-REVIEW
    @MainActor @objc func toggleReview(_ item: NSMenuItem) {
        store.reviewGrid.toggle(); item.state = store.reviewGrid ? .on : .off
    }
    @MainActor @objc func setGridSize(_ item: NSMenuItem) {
        store.gridSize = item.tag
        for i in item.menu?.items ?? [] where i.tag != 0 { i.state = i.tag == item.tag ? .on : .off }
    }
    /// DEV-CURVE — the highlight roll-off knee, ICC / .cube only.
    @MainActor @objc func setRolloff(_ item: NSMenuItem) {
        store.highlightRolloff = [1: 0.20, 2: 0.30, 3: 0.45][item.tag] ?? 0.30
        for i in item.menu?.items ?? [] where i.tag != 0 && i.action == item.action {
            i.state = i.tag == item.tag ? .on : .off
        }
    }
    /// The built-in curve's span, built-in terminator only.
    @MainActor @objc func setSpan(_ item: NSMenuItem) {
        store.printContrast = [1: 1.2, 2: 1.4, 3: 1.6][item.tag] ?? 1.4
        for i in item.menu?.items ?? [] where i.tag != 0 && i.action == item.action {
            i.state = i.tag == item.tag ? .on : .off
        }
    }
    /// DEV-CURVE
    @MainActor @objc func toggleCurve(_ item: NSMenuItem) {
        store.newCurve.toggle(); item.state = store.newCurve ? .on : .off
    }
    // DEV-CAST. A meter and a separate action; nothing measures automatically.
    @MainActor @objc func measureCast() { store.reportRollCast() }
    @MainActor @objc func applyCast() { store.applyRollCast() }
    @MainActor @objc func chooseLCC() { store.chooseLCC() }
    @MainActor @objc func clearLCC() { store.clearLCC() }
    /// The print model is ONE choice: the built-in curve, a .cube, or an ICC.
    /// They all terminate the pipeline the same way, so there is nothing to
    /// "clear" — you pick a different one. Selecting the built-in is what turns
    /// the other two off, which is why `Clear ICC` is gone.
    @MainActor @objc func setPrintModel(_ item: NSMenuItem) {
        store.iccPath = ""             // one print-model slot, one occupant
        store.printLUTPath = (item.representedObject as? String) ?? ""
        syncPrintMenu()
    }
    @MainActor @objc func loadLUT() { store.chooseLUT(); syncPrintMenu() }
    @MainActor @objc func chooseICC() { store.chooseICC(); syncPrintMenu() }  // DEV-ICC

    nonisolated(unsafe) static var printMenu: NSMenu?
    /// Re-tick the whole group from the store, wherever the change came from.
    ///
    /// The ticks used to be set only by `setPrintModel`, and only from the items
    /// it could see — so loading an ICC left "Horizon RA-4 (built-in)" still
    /// ticked while the ICC was rendering, and the menu disagreed with the pixels.
    @MainActor func syncPrintMenu() {
        guard let m = AppActions.printMenu else { return }
        let lut = store.printLUTPath, icc = store.iccPath
        let bundled = Set(PrintLUT.bundled().map(\.path))
        for i in m.items {
            switch i.tag {
            case 1: i.state = lut.isEmpty && icc.isEmpty ? .on : .off
            case 2: i.state = !lut.isEmpty && !bundled.contains(lut) ? .on : .off
            case 3: i.state = icc.isEmpty ? .off : .on
            default:
                if let p = i.representedObject as? String, !p.isEmpty {
                    i.state = p == lut && icc.isEmpty ? .on : .off
                }
            }
        }
    }
    /// DEV-MONO. Capture mode changes the INVERSION, so it says so; film type
    /// changes only the render and takes effect on the next redraw.
    @MainActor @objc func setCapture(_ item: NSMenuItem) {
        store.setShotsPerFrame((item.representedObject as? String ?? "3") == "3")
        syncRollMenus()      // shots-per-frame can settle the film type on its own
    }
    @MainActor @objc func setFilm(_ item: NSMenuItem) {
        store.monochrome = item.tag == 1
        syncRollMenus()
    }
    /// The Film Type ticks, wherever they were changed from.
    @MainActor func syncFilmMenu() {
        guard let sub = filmMenu else { return }
        for i in sub.items { i.state = i.tag == (store.monochrome ? 1 : 0) ? .on : .off }
    }
    /// Set once at menu build. Weak-free: the menu outlives the app.
    nonisolated(unsafe) static var film: NSMenu?
    nonisolated(unsafe) static var capture: NSMenu?
    var filmMenu: NSMenu? { AppActions.film }

    /// Re-tick both roll submenus from the store. Installed as
    /// `RollStore.onRollProps`, so opening a roll or using the import picker
    /// updates them too -- they used to reflect only changes made from the menu.
    @MainActor func syncRollMenus() {
        syncFilmMenu()
        if let sub = AppActions.capture {
            let three = store.captureMode == .rgb3 || store.captureMode == .mono3
            for i in sub.items {
                i.state = (i.representedObject as? String) == (three ? "3" : "1") ? .on : .off
            }
        }
    }

    @MainActor @objc func reinvertFrame() { store.reinvert(selectedOnly: true) }
    @MainActor @objc func reinvertRoll() { store.reinvert(selectedOnly: false) }
    /// ⌘R / ⇧⌘R. In the menu rather than the key monitor so they work in every
    /// view and are discoverable next to their shortcut.
    @MainActor @objc func rotate() { store.rotate() }
    @MainActor @objc func rotateAll() { store.rotateAll() }
}
let actions = MainActor.assumeIsolated { AppActions(store: store) }
MainActor.assumeIsolated {
    RollStore.onRollProps = { [weak actions] in actions?.syncRollMenus() }
}

func item(_ title: String, _ sel: Selector, _ key: String = "",
          _ mods: NSEvent.ModifierFlags = .command, state: NSControl.StateValue? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    i.target = actions
    i.keyEquivalentModifierMask = mods
    if let state { i.state = state }
    return i
}

let mainMenu = NSMenu()

let appItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Horizon", action: nil, keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Hide Horizon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(withTitle: "Quit Horizon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
mainMenu.addItem(appItem)

let fileItem = NSMenuItem()
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(item("Undo", #selector(AppActions.undo), "z"))
fileMenu.addItem(item("Redo", #selector(AppActions.redo), "Z", [.command, .shift]))
fileMenu.addItem(.separator())
fileMenu.addItem(item("New Roll…", #selector(AppActions.newRoll), "n"))
fileMenu.addItem(item("Open Roll…", #selector(AppActions.openRoll), "o"))
fileMenu.addItem(item("Close Roll", #selector(AppActions.closeRoll), "w",
                      [.command, .shift]))
// DEV-RECENT: same list as the idle panel, reachable while a roll is open.
let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
let recentMenu = NSMenu(title: "Open Recent")
// DEV-RECENT: REBUILT EVERY TIME IT OPENS. It was filled once at launch from a
// snapshot and never refreshed, so it kept offering folders that had been moved
// or deleted -- entries the idle screen's own list had already filtered out --
// and it never showed a roll opened during the session either.
final class RecentsMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (i, u) in RollStore.loadRecents().enumerated() {
            let it = NSMenuItem(title: u.lastPathComponent,
                                action: #selector(AppActions.openRecent(_:)),
                                keyEquivalent: i < 9 ? String(i + 1) : "")
            it.keyEquivalentModifierMask = [.command, .control]
            it.target = actions
            it.representedObject = u
            it.toolTip = u.path
            menu.addItem(it)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No Recent Rolls", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }
}
let recentsDelegate = RecentsMenu()
recentMenu.delegate = recentsDelegate
recentItem.submenu = recentMenu
fileMenu.addItem(recentItem)
// ⌘R IS ROTATE, and it lives in the menu so it works in every view.
//
// The app used to bind ⌘R twice: this File item claimed it for re-invert, while
// the key monitor's bare-`r` case swallowed it for rotate. The monitor won,
// because a local monitor runs first — so the menu item was dead and ⌘R rotated.
// When the monitor stopped eating Command keys the menu item came alive and ⌘R
// started RE-INVERTING, which is slow and is not what the key means here.
//
// Rotate keeps ⌘R. Re-invert is F1, this menu, and the panel button — it is a
// slow, roll-touching operation and is better off without a one-finger shortcut.
fileMenu.addItem(.separator())
fileMenu.addItem(item("Rotate", #selector(AppActions.rotate), "r"))
fileMenu.addItem(item("Rotate All", #selector(AppActions.rotateAll), "R",
                      [.command, .shift]))
fileMenu.addItem(.separator())
fileMenu.addItem(item("Re-invert Selected Frame", #selector(AppActions.reinvertFrame)))
fileMenu.addItem(item("Re-invert Whole Roll", #selector(AppActions.reinvertRoll)))
fileMenu.addItem(.separator())
fileMenu.addItem(item("Export Selected Frame", #selector(AppActions.exportSelected), "e"))
fileMenu.addItem(item("Export All Frames", #selector(AppActions.exportAll), "E", [.command, .shift]))
fileItem.submenu = fileMenu
mainMenu.addItem(fileItem)

let setItem = NSMenuItem()
let setMenu = NSMenu(title: "Settings")
let fmt = NSMenuItem(title: "Export Format", action: nil, keyEquivalent: "")
let fmtMenu = NSMenu()
MainActor.assumeIsolated {
    fmtMenu.addItem(item("16-bit TIFF", #selector(AppActions.toggleTIFF), "", .command,
                         state: store.wantTIFF ? .on : .off))
    fmtMenu.addItem(item("JPEG", #selector(AppActions.toggleJPEG), "", .command,
                         state: store.wantJPEG ? .on : .off))
}
MainActor.assumeIsolated {
    fmtMenu.addItem(.separator())
    fmtMenu.addItem(item("Crop to Detected Frame", #selector(AppActions.toggleCropExport),
                         "", .command, state: store.cropExport ? .on : .off))
}
fmt.submenu = fmtMenu
setMenu.addItem(fmt)
setMenu.addItem(.separator())
setMenu.addItem(item("Load LCC / Flat Frame…", #selector(AppActions.chooseLCC), "l"))
setMenu.addItem(item("Clear LCC", #selector(AppActions.clearLCC)))
setMenu.addItem(.separator())
// DEV-MONO: the roll's two properties. Both are also on the import panel; these
// are for changing them afterwards.
MainActor.assumeIsolated {
    // THESE TWO BELONG TO THE ROLL, not to the app, and they are the only such
    // controls in this menu -- everything around them (export format, print
    // model, review grid) is app-wide. They sat loose among those, which is what
    // made them hard to place. Grouped under one heading that says so. Capture
    // carries the one note worth carrying -- it changes the INVERSION, so it does
    // nothing until the roll is re-inverted -- in the same words `setShotsPerFrame`
    // already puts in the status bar. Film needs no note: it is a render property
    // and the picture changes as you pick it. Option wording is untouched, because
    // it matches the import picker, which is the one place this always read clearly.
    let rollItem = NSMenuItem(title: "This Roll", action: nil, keyEquivalent: "")
    let rollSub = NSMenu()

    let capItem = NSMenuItem(title: "Capture (re-invert to apply)", action: nil,
                             keyEquivalent: "")
    let capSub = NSMenu()
    let three = store.captureMode == .rgb3 || store.captureMode == .mono3
    for (tag, label) in [("3", "Trichromatic (RGB)"), ("1", "Single shot")] {
        let i = item(label, #selector(AppActions.setCapture), "", .command,
                     state: (three ? "3" : "1") == tag ? .on : .off)
        i.representedObject = tag
        capSub.addItem(i)
    }
    capItem.submenu = capSub
    AppActions.capture = capSub
    rollSub.addItem(capItem)

    let filmItem = NSMenuItem(title: "Film", action: nil, keyEquivalent: "")
    let filmSub = NSMenu()
    for (tag, label) in [(0, "Colour"), (1, "Black & white")] {
        let i = item(label, #selector(AppActions.setFilm), "", .command,
                     state: (store.monochrome ? 1 : 0) == tag ? .on : .off)
        i.tag = tag
        filmSub.addItem(i)
    }
    filmItem.submenu = filmSub
    AppActions.film = filmSub
    rollSub.addItem(filmItem)

    // No key equivalent: File already owns ⇧⌘R, and two items sharing a shortcut
    // is a bug. This copy is here so the action sits next to the control that
    // requires it.
    rollSub.addItem(.separator())
    rollSub.addItem(item("Re-invert Whole Roll", #selector(AppActions.reinvertRoll)))
    rollItem.submenu = rollSub
    setMenu.addItem(rollItem)
}
// Border detection is NOT a setting. It always runs: the frame rectangle is a
// statistics mask every frame needs, and an off switch only ever produced worse
// colour. Diagnostics are developer tooling and live on the CLI, behind
// `--debug-border`; `--no-border` is there too, for bisecting a bad detection.
// Curve. The two print models own DIFFERENT curve parameters, so each entry says
// which one it affects rather than pretending to be universal: the built-in RA-4
// never clamps and brings its own shoulder, an ICC or .cube clamps and does not.
setMenu.addItem(.separator())
let curveItem = NSMenuItem(title: "Curve", action: nil, keyEquivalent: "")
let curveMenu = NSMenu()
MainActor.assumeIsolated {
    curveMenu.addItem(item("Shouldered Contrast Curve",
                           #selector(AppActions.toggleCurve), "", .command,
                           state: store.newCurve ? .on : .off))
    curveMenu.addItem(.separator())
    let rollTitle = NSMenuItem(title: "Highlight Rolloff  (ICC / .cube)",
                               action: nil, keyEquivalent: "")
    rollTitle.isEnabled = false
    curveMenu.addItem(rollTitle)
    for (tag, label, v) in [(1, "Softer", 0.20), (2, "Normal", 0.30), (3, "Harder", 0.45)] {
        let i = item("   " + label, #selector(AppActions.setRolloff), "", .command,
                     state: store.highlightRolloff == v ? .on : .off)
        i.tag = tag
        curveMenu.addItem(i)
    }
    curveMenu.addItem(.separator())
    let spanTitle = NSMenuItem(title: "Print Contrast  (built-in RA-4)",
                               action: nil, keyEquivalent: "")
    spanTitle.isEnabled = false
    curveMenu.addItem(spanTitle)
    for (tag, label, v) in [(1, "Calmer", 1.2), (2, "Normal", 1.4), (3, "Punchier", 1.6)] {
        let i = item("   " + label, #selector(AppActions.setSpan), "", .command,
                     state: store.printContrast == v ? .on : .off)
        i.tag = tag
        curveMenu.addItem(i)
    }
}
curveItem.submenu = curveMenu
setMenu.addItem(curveItem)

// DEV-REVIEW: the consistency pass, and how many frames it shows.
setMenu.addItem(.separator())
MainActor.assumeIsolated {
    setMenu.addItem(item("Review Grid", #selector(AppActions.toggleReview), "g",
                         .command, state: store.reviewGrid ? .on : .off))
    let gsItem = NSMenuItem(title: "Review Grid Size", action: nil, keyEquivalent: "")
    let gsMenu = NSMenu()
    for n in [6, 8, 12] {
        let i = item("\(n) frames", #selector(AppActions.setGridSize), "", .command,
                     state: store.gridSize == n ? .on : .off)
        i.tag = n
        gsMenu.addItem(i)
    }
    gsItem.submenu = gsMenu
    setMenu.addItem(gsItem)
}

// DEV-CAST: measure the roll's residual cast, then dial it on if it is worth it.
// Two items on purpose -- reading the number and acting on it are different
// decisions, and the reading is the part that is always safe.
setMenu.addItem(.separator())
setMenu.addItem(item("Measure Roll Colour Cast", #selector(AppActions.measureCast), "k"))
setMenu.addItem(item("Apply Roll Colour Cast to All Frames",
                     #selector(AppActions.applyCast), "K", [.command, .shift]))

setMenu.addItem(.separator())
let pmItem = NSMenuItem(title: "Print Emulation", action: nil, keyEquivalent: "")
let pmMenu = NSMenu()
MainActor.assumeIsolated {
    let builtin = item("Horizon RA-4 (built-in)", #selector(AppActions.setPrintModel), "",
                       .command, state: store.printLUTPath.isEmpty ? .on : .off)
    builtin.representedObject = ""
    builtin.tag = 1
    pmMenu.addItem(builtin)
    for u in PrintLUT.bundled() {
        let i = item(u.deletingPathExtension().lastPathComponent,
                     #selector(AppActions.setPrintModel), "", .command,
                     state: store.printLUTPath == u.path ? .on : .off)
        i.representedObject = u.path
        pmMenu.addItem(i)
    }
    pmMenu.addItem(.separator())
    // These two double as the tick for a model that is not in the list above:
    // a .cube from disk, or an ICC. Same slot as the bundled LUTs — they all
    // terminate the pipeline, with the per-frame levels stretch ahead of them.
    let cubeOn = item("Load .cube…", #selector(AppActions.loadLUT))
    cubeOn.tag = 2
    pmMenu.addItem(cubeOn)
    let iccOn = item("Load ICC Print Emulation…", #selector(AppActions.chooseICC), "i")
    iccOn.tag = 3
    pmMenu.addItem(iccOn)
    AppActions.printMenu = pmMenu
    actions.syncPrintMenu()
}
pmItem.submenu = pmMenu
setMenu.addItem(pmItem)
setItem.submenu = setMenu
mainMenu.addItem(setItem)

app.mainMenu = mainMenu

MainActor.assumeIsolated {
    // didSet does not fire for a stored value, so every mirrored default is
    // pushed from one place. See `RollStore.restoreGlobals`.
    store.restoreGlobals()
    installKeyMonitor(store)
    if let f = launchFolder { store.accept(f) }
}
app.activate(ignoringOtherApps: true)
app.run()
