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

/// Reuse the same window and roll when reopening from the Dock. Ordering a
/// minimized window front does not restore it: it must be deminiaturized first.
/// Other visible panels must not prevent the main window from coming back.
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ a: NSApplication,
                                       hasVisibleWindows _: Bool) -> Bool {
        guard let w = window else { return true }
        if w.isMiniaturized { w.deminiaturize(nil) }
        if let dialog = a.modalWindow ?? w.attachedSheet {
            // Keep an open import/export dialog in control of keyboard input.
            w.orderFront(nil)
            dialog.makeKeyAndOrderFront(nil)
        } else {
            w.makeKeyAndOrderFront(nil)
        }
        a.activate(ignoringOtherApps: true)
        return false // The existing window has handled the reopen request.
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
// Closing the window also keeps the current roll available for a Dock reopen.
window.isReleasedWhenClosed = false
window.contentView = NSHostingView(rootView: ContentView(store: store))
window.center()
window.makeKeyAndOrderFront(nil)
delegate.window = window

// Menu bar. Roll and export options live with their corresponding workflow.
final class AppActions: NSObject, NSMenuItemValidation {
    let store: RollStore
    init(store: RollStore) { self.store = store }
    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // A sheet suspends its parent window, but explicit menu targets still
        // need validation so shortcuts cannot start a second roll operation.
        guard !store.isPresentingDialog else { return false }
        switch menuItem.action {
        case #selector(exportSelected): return store.canExport && store.current != nil
        case #selector(exportAll): return store.canExport
        case #selector(editRollSettings), #selector(reinvertRoll),
             #selector(generateBorderDebugImages):
            return store.workspace != nil && !store.isProcessing
        case #selector(toggleCarrierMask(_:)):
            return store.canToggleCarrierMask
        case #selector(reinvertFrame):
            return store.workspace != nil && store.current != nil && !store.isProcessing
                && !store.carrierMaskRequiresReinversion
        case #selector(correctRollColour):
            return !store.frames.isEmpty && !store.isProcessing && !store.carrierMaskRequiresReinversion
        case #selector(showBorderDebugImages):
            return store.hasBorderDebugImages && !store.diagnosingBorders
        case #selector(setRolloff(_:)):
            return (store.usesPrintLUT || store.usesICCPrintModel) && store.newCurve
        case #selector(setSpan(_:)):
            return store.usesBuiltInPrintModel
        default: return true
        }
    }
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
    @MainActor @objc func editRollSettings() { store.editRollDetails() }
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
        syncCurveMenu()
    }
    @MainActor @objc func correctRollColour() { store.correctRollColour() }
    @MainActor @objc func toggleCarrierMask(_ item: NSMenuItem) {
        store.toggleCarrierMask()
        syncRollMenus()
    }
    @MainActor @objc func generateBorderDebugImages() { store.generateBorderDebugImages() }
    @MainActor @objc func showBorderDebugImages() { store.showBorderDebugImages() }
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
    nonisolated(unsafe) static var curveMenu: NSMenu?
    nonisolated(unsafe) static var curveToggleItem: NSMenuItem?
    nonisolated(unsafe) static var automaticCarrierItem: NSMenuItem?
    nonisolated(unsafe) static var carrierReinvertItem: NSMenuItem?
    nonisolated(unsafe) static var borderDebugItem: NSMenuItem?
    nonisolated(unsafe) static var showBorderDebugItem: NSMenuItem?
    nonisolated(unsafe) static var reviewItem: NSMenuItem?
    nonisolated(unsafe) static var gridSizeMenu: NSMenu?
    nonisolated(unsafe) static var correctColourItem: NSMenuItem?
    nonisolated(unsafe) static var rollSettingsItem: NSMenuItem?
    /// Re-tick the whole group from the store, wherever the change came from.
    ///
    /// The ticks used to be set only by `setPrintModel`, and only from the items
    /// it could see — so loading an ICC left "Horizon RA-4 (built-in)" still
    /// ticked while the ICC was rendering, and the menu disagreed with the pixels.
    @MainActor func syncPrintMenu() {
        guard let m = AppActions.printMenu else { return }
        let lut = store.printLUTPath
        let bundled = Set(PrintLUT.bundled().map(\.path))
        for i in m.items {
            switch i.tag {
            case 1: i.state = store.usesBuiltInPrintModel ? .on : .off
            case 2: i.state = store.usesPrintLUT && !bundled.contains(lut) ? .on : .off
            case 3: i.state = store.usesICCPrintModel ? .on : .off
            default:
                if let p = i.representedObject as? String, !p.isEmpty {
                    i.state = store.usesPrintLUT && p == lut ? .on : .off
                }
            }
        }
        syncCurveMenu()
    }
    @MainActor func syncCurveMenu() {
        guard let menu = AppActions.curveMenu else { return }
        let externalPrint = store.usesPrintLUT || store.usesICCPrintModel
        AppActions.curveToggleItem?.state = store.newCurve ? .on : .off
        for i in menu.items {
            if i.action == #selector(AppActions.setRolloff) {
                i.isEnabled = externalPrint && store.newCurve
                i.toolTip = "Available with a .cube or ICC print emulation when Shouldered Contrast Curve is on."
            } else if i.action == #selector(AppActions.setSpan) {
                i.isEnabled = store.usesBuiltInPrintModel
                i.toolTip = "Choose Settings → Print Emulation → Horizon RA-4 (built-in)."
            }
        }
    }
    /// DEV-MONO. Capture mode changes the INVERSION, so it says so; film type
    /// changes only the render and takes effect on the next redraw.
    @MainActor @objc func setCapture(_ item: NSMenuItem) {
        guard !store.isProcessing else { return }
        store.setShotsPerFrame((item.representedObject as? String ?? "3") == "3")
        syncRollMenus()      // shots-per-frame can settle the film type on its own
    }
    @MainActor @objc func setFilm(_ item: NSMenuItem) {
        guard !store.isProcessing else { return }
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
        AppActions.automaticCarrierItem?.state = store.carrierMaskEnabled ? .on : .off
        AppActions.automaticCarrierItem?.isEnabled = store.canToggleCarrierMask
        AppActions.automaticCarrierItem?.toolTip = store.automaticCarrierDescription
        AppActions.carrierReinvertItem?.title = store.carrierMaskRequiresReinversion
            ? "Re-invert Whole Roll to Apply Carrier Change…" : "Re-invert Whole Roll"
        AppActions.carrierReinvertItem?.isEnabled = store.workspace != nil && !store.isProcessing
        AppActions.borderDebugItem?.isEnabled = store.workspace != nil && !store.isProcessing
        AppActions.showBorderDebugItem?.isEnabled = store.hasBorderDebugImages && !store.diagnosingBorders
        AppActions.rollSettingsItem?.isEnabled = store.workspace != nil && !store.isProcessing
        AppActions.correctColourItem?.isEnabled = !store.frames.isEmpty && !store.isProcessing
            && !store.carrierMaskRequiresReinversion
        AppActions.reviewItem?.state = store.reviewGrid ? .on : .off
        for item in AppActions.gridSizeMenu?.items ?? [] {
            item.state = item.tag == store.gridSize ? .on : .off
        }
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

final class WorkflowMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            actions.syncRollMenus()
            actions.syncPrintMenu()
        }
    }
}
let workflowMenuDelegate = WorkflowMenuDelegate()

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
let rollSettingsItem = item("Roll Settings…", #selector(AppActions.editRollSettings))
AppActions.rollSettingsItem = rollSettingsItem
fileMenu.addItem(rollSettingsItem)
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
        for (i, roll) in RollStore.loadRecentOrders().enumerated() {
            let it = NSMenuItem(title: roll.title,
                                action: #selector(AppActions.openRecent(_:)),
                                keyEquivalent: i < 9 ? String(i + 1) : "")
            it.keyEquivalentModifierMask = [.command, .control]
            it.target = actions
            it.representedObject = roll.url
            if !roll.subtitle.isEmpty {
                let title = NSMutableAttributedString(string: roll.title, attributes: [
                    .font: NSFont.menuFont(ofSize: 0)
                ])
                title.append(NSAttributedString(string: "  ·  " + roll.subtitle, attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
                it.attributedTitle = title
            }
            it.toolTip = roll.tooltip
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
fileMenu.delegate = workflowMenuDelegate
mainMenu.addItem(fileItem)

let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
let correctColourItem = item("Correct Roll Colour", #selector(AppActions.correctRollColour), "k")
AppActions.correctColourItem = correctColourItem
editMenu.addItem(correctColourItem)
editItem.submenu = editMenu
editMenu.delegate = workflowMenuDelegate
mainMenu.addItem(editItem)

let viewItem = NSMenuItem()
let viewMenu = NSMenu(title: "View")
MainActor.assumeIsolated {
    let review = item("Review Grid", #selector(AppActions.toggleReview), "g",
                      .command, state: store.reviewGrid ? .on : .off)
    AppActions.reviewItem = review
    viewMenu.addItem(review)
    let grid = NSMenuItem(title: "Review Grid Size", action: nil, keyEquivalent: "")
    let sizes = NSMenu()
    for n in [6, 8, 12] {
        let i = item("\(n) frames", #selector(AppActions.setGridSize), "", .command,
                     state: store.gridSize == n ? .on : .off)
        i.tag = n
        sizes.addItem(i)
    }
    grid.submenu = sizes
    AppActions.gridSizeMenu = sizes
    viewMenu.addItem(grid)
}
viewItem.submenu = viewMenu
viewMenu.delegate = workflowMenuDelegate
mainMenu.addItem(viewItem)

let setItem = NSMenuItem()
let setMenu = NSMenu(title: "Settings")
MainActor.assumeIsolated {
    let carrier = item("Automatic Carrier Handling — Beta", #selector(AppActions.toggleCarrierMask(_:)),
                       "", .command, state: store.carrierMaskEnabled ? .on : .off)
    carrier.toolTip = store.automaticCarrierDescription
    AppActions.automaticCarrierItem = carrier
    setMenu.addItem(carrier)
    let reinvert = item("Re-invert Whole Roll", #selector(AppActions.reinvertRoll))
    AppActions.carrierReinvertItem = reinvert
    setMenu.addItem(reinvert)
    let debug = item("Generate Border Debug Images…", #selector(AppActions.generateBorderDebugImages))
    debug.toolTip = "Generate inspection PNGs without changing the roll or its carrier setting."
    AppActions.borderDebugItem = debug
    setMenu.addItem(debug)
    let showDebug = item("Show Border Debug Images", #selector(AppActions.showBorderDebugImages))
    AppActions.showBorderDebugItem = showDebug
    setMenu.addItem(showDebug)
}
setMenu.addItem(.separator())
let curveItem = NSMenuItem(title: "Curve", action: nil, keyEquivalent: "")
let curveMenu = NSMenu()
MainActor.assumeIsolated {
    let shouldered = item("Shouldered Contrast Curve", #selector(AppActions.toggleCurve),
                          "", .command, state: store.newCurve ? .on : .off)
    AppActions.curveToggleItem = shouldered
    curveMenu.addItem(shouldered)
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
curveMenu.delegate = workflowMenuDelegate
AppActions.curveMenu = curveMenu
MainActor.assumeIsolated { actions.syncCurveMenu() }
setMenu.addItem(curveItem)

setMenu.addItem(.separator())
let pmItem = NSMenuItem(title: "Print Emulation", action: nil, keyEquivalent: "")
let pmMenu = NSMenu()
MainActor.assumeIsolated {
    let builtin = item("Horizon RA-4 (built-in)", #selector(AppActions.setPrintModel), "",
                       .command, state: store.usesBuiltInPrintModel ? .on : .off)
    builtin.representedObject = ""
    builtin.tag = 1
    pmMenu.addItem(builtin)
    for u in PrintLUT.bundled() {
        let i = item(u.deletingPathExtension().lastPathComponent,
                     #selector(AppActions.setPrintModel), "", .command,
                     state: store.usesPrintLUT && store.printLUTPath == u.path ? .on : .off)
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
setMenu.addItem(.separator())
let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
let advancedMenu = NSMenu()
advancedMenu.addItem(item("Choose Flat-Field Reference…", #selector(AppActions.chooseLCC), "l"))
advancedMenu.addItem(item("Clear Flat-Field Reference", #selector(AppActions.clearLCC)))
advanced.submenu = advancedMenu
setMenu.addItem(advanced)
setItem.submenu = setMenu
setMenu.delegate = workflowMenuDelegate
mainMenu.addItem(setItem)

app.mainMenu = mainMenu

MainActor.assumeIsolated {
    // didSet does not fire for a stored value, so every mirrored default is
    // pushed from one place. See `RollStore.restoreGlobals`.
    store.restoreGlobals()
    actions.syncPrintMenu()
    actions.syncRollMenus()
    installKeyMonitor(store)
    if let f = launchFolder { store.accept(f) }
}
app.activate(ignoringOtherApps: true)
app.run()
