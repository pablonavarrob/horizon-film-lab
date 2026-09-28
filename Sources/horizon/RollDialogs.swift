import AppKit
import SwiftUI

struct RollImportOptions {
    let layout: Invert.Layout
    let monochrome: Bool
    let metadata: RollMetadata
}

@MainActor
enum RollDialogs {
    static func presentImport(folder: URL, captureCount: Int,
                              suggestedLayout: Invert.Layout,
                              suggestedMonochrome: Bool,
                              metadata: RollMetadata,
                              for parentWindow: NSWindow) async -> RollImportOptions? {
        await presentRoll(folder: folder, captureCount: captureCount,
                          layout: suggestedLayout, monochrome: suggestedMonochrome,
                          metadata: metadata,
                          settings: false, for: parentWindow)
    }

    static func presentRollSettings(folder: URL, captureCount: Int,
                                    suggestedLayout: Invert.Layout,
                                    suggestedMonochrome: Bool,
                                    metadata: RollMetadata,
                                    for parentWindow: NSWindow) async -> RollImportOptions? {
        await presentRoll(folder: folder, captureCount: captureCount,
                          layout: suggestedLayout, monochrome: suggestedMonochrome,
                          metadata: metadata,
                          settings: true, for: parentWindow)
    }

    private static func presentRoll(folder: URL, captureCount: Int,
                                    layout: Invert.Layout, monochrome: Bool,
                                    metadata: RollMetadata,
                                    settings: Bool,
                                    for parentWindow: NSWindow) async -> RollImportOptions? {
        var initial = metadata
        if initial.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initial.title = folder.lastPathComponent
        }
        let draft = RollDraft(metadata: initial,
                              threeShot: layout == .rgb3 || layout == .mono3,
                              monochrome: monochrome,
                              monoFiles: layout == .mono1 || layout == .mono3)
        let visibleHeight = parentWindow.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 700
        let dialogHeight = min(620, max(360, visibleHeight - 48))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                                width: 600, height: dialogHeight),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = settings ? "Roll Settings" : "Import Roll"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = NSColor(FUI.silver)
        let content = NSHostingView(rootView: RollDialogView(
            draft: draft, folder: folder, captureCount: captureCount,
            settings: settings, height: dialogHeight,
            cancel: { [weak parentWindow, weak panel] in
                guard let parentWindow, let panel else { return }
                parentWindow.endSheet(panel, returnCode: .cancel)
            },
            accept: { [weak parentWindow, weak panel] in
                guard settings || (captureCount > 0 &&
                    (!draft.threeShot || captureCount % 3 == 0)) else {
                    NSSound.beep(); return
                }
                guard let parentWindow, let panel else { return }
                parentWindow.endSheet(panel, returnCode: .OK)
            }))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            parentWindow.beginSheet(panel) { code in continuation.resume(returning: code) }
        }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        guard response == .OK else { return nil }
        let resolved = Invert.layoutAndFilm(threeShot: draft.threeShot, mono: draft.monoFiles)
        return RollImportOptions(layout: resolved.layout,
                                 monochrome: resolved.monochrome ||
                                     (!resolved.settled && draft.monochrome),
                                 metadata: draft.metadata)
    }

    static func presentMetadata(folder: URL, metadata: RollMetadata,
                                for parentWindow: NSWindow,
                                save: @escaping (RollMetadata) throws -> Void) async {
        let draft = MetadataDraft(metadata: metadata, folder: folder)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Roll Metadata"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = NSColor(FUI.silver)
        panel.contentView = NSHostingView(rootView: RollMetadataDialogView(
            draft: draft, folder: folder,
            cancel: { [weak parentWindow, weak panel] in
                guard let parentWindow, let panel else { return }
                parentWindow.endSheet(panel, returnCode: .cancel)
            },
            accept: { [weak parentWindow, weak panel] in
                guard let parentWindow, let panel else { return }
                do {
                    try save(draft.metadata)
                    parentWindow.endSheet(panel, returnCode: .OK)
                } catch {
                    // Keep the draft editable so the user can fix or retry a failed save.
                    draft.saveError = error.localizedDescription
                }
            }))
        let _: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            parentWindow.beginSheet(panel) { code in continuation.resume(returning: code) }
        }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    static func presentExport(metadata: RollMetadata, originalNames: [String],
                              wantTIFF: Bool, wantJPEG: Bool,
                              cropExport: Bool,
                              frameNumbers: [Int]? = nil,
                              for parentWindow: NSWindow) async -> ExportRequest? {
        guard !originalNames.isEmpty else { return nil }
        let chooser = NSOpenPanel()
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.canCreateDirectories = true
        chooser.prompt = "Choose export location"
        chooser.message = "Choose where the exported photographs will go"
        let parent = await withCheckedContinuation { continuation in
            chooser.beginSheetModal(for: parentWindow) { response in
                continuation.resume(returning: response == .OK ? chooser.url : nil)
            }
        }
        guard let parent else { return nil }

        let draft = ExportDraft(metadata: metadata, parent: parent,
                                originalNames: originalNames,
                                wantTIFF: wantTIFF, wantJPEG: wantJPEG,
                                cropExport: cropExport, frameNumbers: frameNumbers)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Export Photographs"
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = NSColor(FUI.silver)
        let content = NSHostingView(rootView: ExportDialogView(
            draft: draft,
            cancel: { [weak parentWindow, weak panel] in
                guard let parentWindow, let panel else { return }
                parentWindow.endSheet(panel, returnCode: .cancel)
            },
            accept: { [weak parentWindow, weak panel] in
                guard draft.problem == nil else { NSSound.beep(); return }
                guard let parentWindow, let panel else { return }
                parentWindow.endSheet(panel, returnCode: .OK)
            }))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            parentWindow.beginSheet(panel) { code in continuation.resume(returning: code) }
        }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        guard response == .OK else { return nil }
        return draft.request
    }
}

@MainActor
private final class MetadataDraft: ObservableObject {
    @Published var metadata: RollMetadata
    @Published var saveError: String?

    init(metadata: RollMetadata, folder: URL) {
        var initial = metadata
        if initial.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initial.title = folder.lastPathComponent
        }
        initial.applyFilmDefaults()
        self.metadata = initial
    }
}

@MainActor
private struct RollMetadataDialogView: View {
    @ObservedObject var draft: MetadataDraft
    let folder: URL
    let cancel: () -> Void
    let accept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(folder.lastPathComponent).font(FUI.heading())
                    .lineLimit(1).truncationMode(.middle).help(folder.path)
                Spacer(minLength: 12)
                Text("ROLL METADATA").font(FUI.small(true))
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(LinearGradient(colors: [FUI.tealTop, FUI.tealBot],
                                       startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { FUI.tealRule.frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RollMetadataFields(metadata: $draft.metadata)
                    if let error = draft.saveError {
                        Text(error).font(FUI.small()).foregroundStyle(FUI.inkRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(Chunky(height: 34, minWidth: 84))
                    .keyboardShortcut(.cancelAction)
                Button("Save Metadata", action: accept)
                    .buttonStyle(StartButton(height: 34, minWidth: 128))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(FUI.panelWell)
            .overlay(alignment: .top) { FUI.hiLight.frame(height: 1) }
        }
        .foregroundStyle(FUI.ink)
        .background(FUI.silver)
        .frame(width: 600, height: 520)
        .environment(\.colorScheme, .light)
    }
}

@MainActor
private final class RollDraft: ObservableObject {
    @Published var metadata: RollMetadata
    @Published var threeShot: Bool
    @Published var monochrome: Bool
    let monoFiles: Bool

    init(metadata: RollMetadata, threeShot: Bool, monochrome: Bool,
         monoFiles: Bool) {
        var initial = metadata
        initial.applyFilmDefaults()
        self.metadata = initial; self.threeShot = threeShot
        self.monochrome = (monoFiles && !threeShot) || monochrome
        self.monoFiles = monoFiles
    }
}

@MainActor
private struct RollDialogView: View {
    @ObservedObject var draft: RollDraft
    let folder: URL
    let captureCount: Int
    let settings: Bool
    let height: CGFloat
    let cancel: () -> Void
    let accept: () -> Void

    private var frameCount: Int { draft.threeShot ? captureCount / 3 : captureCount }
    private var countProblem: String? {
        if settings { return nil }
        if captureCount == 0 && !settings { return "This folder contains no supported captures." }
        if draft.threeShot && captureCount % 3 != 0 {
            return "Three captures per frame needs a multiple of 3 files."
        }
        return nil
    }

    private var footnote: String {
        if let countProblem { return countProblem }
        return settings ? "After capture changes, use Re-invert Whole Roll."
                        : "Original capture files keep their names."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    capturePanel
                    RollMetadataFields(metadata: $draft.metadata)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .foregroundStyle(FUI.ink)
        .background(FUI.silver)
        .frame(width: 600, height: height)
        .environment(\.colorScheme, .light)
        .onChange(of: draft.threeShot) { _, three in
            if draft.monoFiles && !three { draft.monochrome = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let badge = FUI.badge {
                Image(nsImage: badge).resizable().scaledToFit().frame(width: 38, height: 32)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.lastPathComponent).font(FUI.heading())
                    .lineLimit(1).truncationMode(.middle).help(folder.path)
                Text("\(captureCount) capture files → \(frameCount) frames")
                    .font(FUI.small())
            }
            Spacer(minLength: 12)
            Text(settings ? "ROLL SETTINGS" : "IMPORT ROLL")
                .font(FUI.small(true))
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(LinearGradient(colors: [FUI.tealTop, FUI.tealBot],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { FUI.tealRule.frame(height: 1) }
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            choiceRow("Capture", selection: $draft.threeShot,
                      first: "One capture per frame", second: "Three RGB captures per frame")
            choiceRow("Film", selection: $draft.monochrome,
                      first: "Colour negative", second: "Black & white negative")
                .disabled(draft.monoFiles && !draft.threeShot)
                .opacity(draft.monoFiles && !draft.threeShot ? 0.55 : 1)
                .help(draft.monoFiles && !draft.threeShot
                      ? "Single channel captures are black and white."
                      : "Choose the photographic film type.")
        }
        .padding(12)
        .background(FUI.panelWell)
        .bevel(up: false, width: 1)
    }

    private func choiceRow(_ title: String, selection: Binding<Bool>,
                           first: String, second: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(FUI.label(true)).frame(width: 58, alignment: .leading)
            Button(first) { selection.wrappedValue = false }
                .buttonStyle(Chunky(height: 30, lit: !selection.wrappedValue))
                .accessibilityAddTraits(!selection.wrappedValue ? .isSelected : [])
            Button(second) { selection.wrappedValue = true }
                .buttonStyle(Chunky(height: 30, lit: selection.wrappedValue))
                .accessibilityAddTraits(selection.wrappedValue ? .isSelected : [])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footnote).font(FUI.small())
                .foregroundStyle(countProblem == nil ? FUI.ink.opacity(0.75) : FUI.inkRed)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: cancel)
                .buttonStyle(Chunky(height: 34, minWidth: 84))
                .keyboardShortcut(.cancelAction)
            Button(settings ? "Save Roll Settings" : "Import Roll", action: accept)
                .buttonStyle(StartButton(height: 34, minWidth: 128))
                .keyboardShortcut(.defaultAction)
                .disabled(countProblem != nil)
                .opacity(countProblem == nil ? 1 : 0.45)
        }
        .padding(12)
        .background(FUI.panelWell)
        .overlay(alignment: .top) { FUI.hiLight.frame(height: 1) }
    }
}

@MainActor
private struct RollMetadataFields: View {
    @Binding var metadata: RollMetadata
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeading("Roll metadata")
            VStack(spacing: 10) {
                field("Roll title", $metadata.title, hint: "Name this roll")
                HStack(spacing: 12) {
                    CatalogField("Film stock", value: stockBinding,
                                 hint: "Choose film", groups: FilmChoices.stocks)
                    CatalogField("Film format", value: $metadata.format,
                                 hint: "Choose", groups: FilmChoices.formats).frame(width: 104)
                    if FilmStockCatalog.boxISO(for: metadata.stock) != nil {
                        readOnlyValue("Box ISO", metadata.boxISO).frame(width: 82)
                    } else {
                        CatalogField("Box ISO", value: boxISOBinding,
                                     hint: "Unset", groups: FilmChoices.speeds).frame(width: 82)
                    }
                    CatalogField("Shot at EI", value: shootingEIBinding,
                                 hint: "Box speed", groups: FilmChoices.speeds,
                                 resetTitle: "Box speed").frame(width: 82)
                }
                HStack(spacing: 12) {
                    field("Film camera", $metadata.filmCamera, hint: "Camera body")
                    field("Film lens", $metadata.filmLens, hint: "Lens / focal length")
                }
                HStack(spacing: 12) {
                    PhotoDateField(value: $metadata.photographDate)
                    field("Location", $metadata.location, hint: "Place")
                }
                field("Development notes", $metadata.developmentNotes,
                      hint: "Lab, chemistry, push / pull…")
            }
            .padding(12)
        }
        .bevel(width: 1)
    }

    private var stockBinding: Binding<String> {
        Binding(get: { metadata.stock },
                set: {
                    var updated = metadata
                    updated.selectFilmStock($0)
                    metadata = updated
                })
    }

    private var boxISOBinding: Binding<String> {
        Binding(get: { metadata.boxISO },
                set: {
                    var updated = metadata
                    updated.setBoxISO($0)
                    metadata = updated
                })
    }

    private var shootingEIBinding: Binding<String> {
        Binding(get: {
            metadata.shootingEI.isEmpty
                ? metadata.boxISO : metadata.shootingEI
        }, set: {
            var updated = metadata
            updated.setShootingEI($0)
            metadata = updated
        })
    }

    private func readOnlyValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FUI.small(true)).foregroundStyle(FUI.ink.opacity(0.75))
            Text(value.isEmpty ? "—" : value)
                .font(FUI.label())
                .foregroundStyle(FUI.ink)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28,
                       alignment: .center)
                .background(FUI.fieldRO)
                .bevel(up: false, width: 1)
                .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55)))
                .accessibilityLabel(title)
                .accessibilityValue(value)
                .help("Box speed supplied by the selected film stock")
        }
    }

    private func field(_ title: String, _ value: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FUI.small(true)).foregroundStyle(FUI.ink.opacity(0.75))
            TextField(title, text: value,
                      prompt: Text(hint).foregroundColor(FUI.ink.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(FUI.label())
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(FUI.fieldWhite)
                .bevel(up: false, width: 1)
                .overlay(Rectangle().strokeBorder(
                    focusedField == title ? FUI.tealRule : FUI.outline.opacity(0.55),
                    lineWidth: focusedField == title ? 2 : 1).allowsHitTesting(false))
                .focused($focusedField, equals: title)
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct CatalogGroup: Identifiable {
    let title: String
    let values: [String]
    var id: String { title }
}

private enum FilmChoices {
    static let stocks: [CatalogGroup] = FilmStockCatalog.groups.map {
        CatalogGroup(title: $0.title, values: $0.stocks.map(\.name))
    }

    static let formats: [CatalogGroup] = [
        .init(title: "Film format", values: [
            "110", "35 mm", "35 mm half-frame", "120", "120 6×4.5",
            "120 6×6", "120 6×7", "120 6×9", "220", "4×5 in", "8×10 in"
        ])
    ]

    /// Standard full and third-stop ISO/EI values. A custom value remains
    /// available for pushed film or a rating outside this range.
    static let speeds: [CatalogGroup] = [
        .init(title: "ISO / EI", values: [
            "3", "4", "5", "6", "8", "10", "12", "16", "20", "25",
            "32", "40", "50", "64", "80", "100", "125", "160", "200",
            "250", "320", "400", "500", "640", "800", "1000", "1250",
            "1600", "2000", "2500", "3200", "4000", "5000", "6400",
            "8000", "10000", "12800", "16000", "20000", "25600"
        ])
    ]
}

/// A native menu keeps selection reliable inside the roll sheet.
/// Custom… accepts any value outside the catalog.
private struct CatalogField: View {
    let title: String
    @Binding var value: String
    let hint: String
    let groups: [CatalogGroup]
    let resetTitle: String
    @State private var showingCustom = false
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    init(_ title: String, value: Binding<String>, hint: String,
         groups: [CatalogGroup], resetTitle: String = "Unset") {
        self.title = title; self._value = value; self.hint = hint
        self.groups = groups; self.resetTitle = resetTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FUI.small(true)).foregroundStyle(FUI.ink.opacity(0.75))
            NativeCatalogMenu(title: title, value: $value, hint: hint,
                              groups: groups, resetTitle: resetTitle) {
                    customText = value
                    showingCustom = true
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28,
                   alignment: .leading)
            .background(FUI.fieldWhite)
            .bevel(up: false, width: 1)
            .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55))
                .allowsHitTesting(false))
            .popover(isPresented: $showingCustom, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom \(title.lowercased())").font(FUI.label(true))
                    TextField(title, text: $customText)
                        .textFieldStyle(.plain)
                        .font(FUI.label())
                        .padding(8)
                        .background(FUI.fieldWhite)
                        .bevel(up: false, width: 1)
                        .focused($customFocused)
                    HStack {
                        Spacer()
                        Button("Cancel") { showingCustom = false }
                            .buttonStyle(Chunky(height: 28, minWidth: 65))
                        Button("Use Custom") {
                            value = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                            showingCustom = false
                        }
                        .buttonStyle(StartButton(height: 28, minWidth: 105))
                    }
                }
                .padding(12)
                .frame(width: 250)
                .background(FUI.silver)
                .environment(\.colorScheme, .light)
                .onAppear { customFocused = true }
            }
            .accessibilityLabel(title)
            .accessibilityValue(value.isEmpty ? "Unset" : value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct NativeCatalogMenu: NSViewRepresentable {
    let title: String
    @Binding var value: String
    let hint: String
    let groups: [CatalogGroup]
    let resetTitle: String
    let onCustom: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.cell = InsetCatalogButtonCell(textCell: "")
        button.target = context.coordinator
        button.action = #selector(Coordinator.open(_:))
        button.isBordered = false
        button.alignment = .left
        button.font = NSFont(name: "Tahoma", size: 13) ?? .systemFont(ofSize: 13)
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageRight
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = value.isEmpty ? hint : value
        button.contentTintColor = value.isEmpty
            ? NSColor(FUI.ink).withAlphaComponent(0.4) : NSColor(FUI.ink)
        button.setAccessibilityValue(value.isEmpty ? "Unset" : value)
    }

    final class Coordinator: NSObject {
        var parent: NativeCatalogMenu
        private var wantsCustom = false

        init(_ parent: NativeCatalogMenu) { self.parent = parent }

        @objc func open(_ sender: NSButton) {
            wantsCustom = false
            let menu = buildMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height),
                       in: sender)
            sender.title = parent.value.isEmpty ? parent.hint : parent.value
            if wantsCustom { parent.onCustom() }
        }

        fileprivate func buildMenu() -> NSMenu {
            let menu = NSMenu()
            let reset = item(parent.resetTitle, value: "")
            reset.state = parent.value.isEmpty ? .on : .off
            menu.addItem(reset)
            menu.addItem(.separator())
            if parent.groups.count == 1, let group = parent.groups.first {
                addChoices(group.values, to: menu)
            } else {
                for group in parent.groups {
                    let submenu = NSMenu(title: group.title)
                    addChoices(group.values, to: submenu)
                    let heading = NSMenuItem(title: group.title, action: nil,
                                             keyEquivalent: "")
                    heading.submenu = submenu
                    menu.addItem(heading)
                }
            }
            menu.addItem(.separator())
            let custom = NSMenuItem(title: "Custom…", action: #selector(useCustom),
                                    keyEquivalent: "")
            custom.target = self
            menu.addItem(custom)
            return menu
        }

        private func addChoices(_ choices: [String], to menu: NSMenu) {
            for choice in choices {
                let option = item(choice, value: choice)
                option.state = parent.value == choice ? .on : .off
                menu.addItem(option)
            }
        }

        private func item(_ title: String, value: String) -> NSMenuItem {
            let option = NSMenuItem(title: title, action: #selector(select(_:)),
                                    keyEquivalent: "")
            option.target = self
            option.representedObject = value
            return option
        }

        @objc private func select(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            parent.value = value
        }

        @objc private func useCustom() {
            wantsCustom = true
        }
    }
}

/// The entire button remains clickable; only its drawn title and chevron are
/// inset from the field border, matching the surrounding text fields.
private final class InsetCatalogButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let title = super.titleRect(forBounds: rect)
        return NSRect(x: title.minX + 8, y: title.minY,
                      width: max(0, title.width - 16), height: title.height)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: rect).offsetBy(dx: -8, dy: 0)
    }
}

/// The popover uses a native calendar for exact dates and month/year controls
/// for partial dates. Opening it does not write a date: an old free-text value
/// survives until the operator presses Use Date.
private struct PhotoDateField: View {
    @Binding var value: String
    @State private var showingCalendar = false
    @State private var selectedDate = Date()
    @State private var precision: PhotoDate.Precision = .day
    @State private var selectedMonth = 1
    @State private var yearText = ""

    private var monthNames: [String] {
        var calendar = PhotoDate.calendar()
        calendar.locale = .current
        return calendar.monthSymbols
    }
    private var currentYear: Int { PhotoDate.calendar().component(.year, from: Date()) }
    private var validYear: Int? {
        guard let year = Int(yearText), (1...9999).contains(year) else { return nil }
        return year
    }

    private func components(of date: Date) -> DateComponents {
        PhotoDate.calendar().dateComponents([.year, .month, .day], from: date)
    }

    private func date(year: Int, month: Int, day: Int = 1) -> Date? {
        PhotoDate.calendar().date(from: DateComponents(year: year, month: month,
                                                       day: day, hour: 12))
    }

    private func openCalendar() {
        let saved = PhotoDate.parseSelection(value)
        let date = saved?.date ?? Date()
        let parts = components(of: date)
        selectedDate = date
        selectedMonth = parts.month ?? 1
        yearText = String(parts.year ?? currentYear)
        precision = saved?.precision ?? .day
        showingCalendar = true
    }

    private func changePrecision(to next: PhotoDate.Precision) {
        guard next != precision else { return }
        if precision == .day {
            let parts = components(of: selectedDate)
            selectedMonth = parts.month ?? selectedMonth
            yearText = String(parts.year ?? currentYear)
        } else if next == .day, let year = validYear,
                  let first = date(year: year, month: selectedMonth),
                  let days = PhotoDate.calendar().range(of: .day, in: .month, for: first) {
            let originalDay = components(of: selectedDate).day ?? 1
            selectedDate = date(year: year, month: selectedMonth,
                                day: min(originalDay, days.count)) ?? first
        }
        precision = next
    }

    private func commit() {
        let chosen: Date
        if precision == .day {
            chosen = selectedDate
        } else {
            guard let year = validYear,
                  let partial = date(year: year,
                                     month: precision == .month ? selectedMonth : 1) else { return }
            chosen = partial
        }
        value = PhotoDate.serialize(chosen, precision: precision)
        showingCalendar = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Photograph date").font(FUI.small(true))
                .foregroundStyle(FUI.ink.opacity(0.75))
            Button {
                openCalendar()
            } label: {
                HStack(spacing: 4) {
                    Text(value.isEmpty ? "Choose a date" : value)
                        .foregroundStyle(value.isEmpty ? FUI.ink.opacity(0.4) : FUI.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(FUI.ink.opacity(0.65))
                }
                .font(FUI.label())
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(FUI.fieldWhite)
                .bevel(up: false, width: 1)
                .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Photograph date").font(FUI.label(true))
                    if !value.isEmpty && PhotoDate.parseSelection(value) == nil {
                        Text("Existing: \(value)").font(FUI.small())
                            .foregroundStyle(FUI.ink.opacity(0.7))
                    }
                    HStack(spacing: 4) {
                        Button("Date") { changePrecision(to: .day) }
                            .buttonStyle(Chunky(height: 28, lit: precision == .day))
                        Button("Month & year") { changePrecision(to: .month) }
                            .buttonStyle(Chunky(height: 28, lit: precision == .month))
                        Button("Year only") { changePrecision(to: .year) }
                            .buttonStyle(Chunky(height: 28, lit: precision == .year))
                    }
                    if precision == .day {
                        DatePicker("Photograph date", selection: $selectedDate,
                                   displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .environment(\.calendar, PhotoDate.calendar())
                            .environment(\.timeZone, TimeZone.current)
                    } else {
                        HStack(spacing: 8) {
                            if precision == .year { Spacer(minLength: 0) }
                            if precision == .month {
                                Menu {
                                    ForEach(1...12, id: \.self) { month in
                                        Button(monthNames[month - 1]) { selectedMonth = month }
                                    }
                                } label: {
                                    Text(monthNames[selectedMonth - 1])
                                        .font(FUI.label()).lineLimit(1)
                                }
                                .menuStyle(.borderlessButton)
                                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28,
                                       alignment: .leading)
                                .background(FUI.fieldWhite)
                                .bevel(up: false, width: 1)
                                .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55))
                                    .allowsHitTesting(false))
                                .accessibilityLabel("Month")
                            }
                            TextField("Year", text: $yearText)
                                .textFieldStyle(.plain)
                                .font(FUI.label())
                                .padding(.horizontal, 8)
                                .frame(width: 72, height: 28)
                                .background(FUI.fieldWhite)
                                .bevel(up: false, width: 1)
                                .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55)))
                                .accessibilityLabel("Year")
                            Stepper("Year", value: Binding(
                                get: { validYear ?? (components(of: selectedDate).year ?? currentYear) },
                                set: { yearText = String($0) }), in: 1...9999)
                                .labelsHidden()
                                .help("Increase or decrease the year")
                            if precision == .year { Spacer(minLength: 0) }
                        }
                        if validYear == nil {
                            Text("Enter a year from 1 to 9999.")
                                .font(FUI.small()).foregroundStyle(FUI.inkRed)
                        }
                    }
                    HStack {
                        if !value.isEmpty {
                            Button("Clear") { value = ""; showingCalendar = false }
                                .buttonStyle(Chunky(height: 28, minWidth: 60))
                        }
                        Spacer()
                        Button("Cancel") { showingCalendar = false }
                            .buttonStyle(Chunky(height: 28, minWidth: 65))
                        Button("Use Date", action: commit)
                            .buttonStyle(StartButton(height: 28, minWidth: 90))
                            .disabled(precision != .day && validYear == nil)
                    }
                }
                .padding(12)
                .frame(width: 315)
                .background(FUI.silver)
                .environment(\.colorScheme, .light)
            }
            .accessibilityLabel("Photograph date")
            .accessibilityValue(value.isEmpty ? "Unset" : value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RollCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Rectangle().fill(FUI.fieldWhite)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    }
                }
                .frame(width: 16, height: 16)
                .bevel(up: false, width: 1)
                .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55)))
                configuration.label
            }
            .foregroundStyle(FUI.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

@MainActor
final class ExportDraft: ObservableObject {
    @Published var folderChoice = 1  // 0 = destination, 1 = roll title, 2 = custom
    @Published var customFolder = ""
    @Published var filenamePattern = ExportNaming.defaultPattern
    @Published var wantTIFF: Bool
    @Published var wantJPEG: Bool
    @Published var cropExport: Bool
    let metadata: RollMetadata
    let parent: URL
    let originalNames: [String]
    let frameNumbers: [Int]?

    init(metadata: RollMetadata, parent: URL, originalNames: [String],
         wantTIFF: Bool, wantJPEG: Bool, cropExport: Bool,
         frameNumbers: [Int]?) {
        self.metadata = metadata; self.parent = parent; self.originalNames = originalNames
        self.frameNumbers = frameNumbers
        self.wantTIFF = wantTIFF; self.wantJPEG = wantJPEG; self.cropExport = cropExport
        if metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            folderChoice = 0
        }
    }

    var request: ExportRequest {
        let folder: String?
        switch folderChoice {
        case 1:
            folder = (try? ExportNaming.safeComponent(metadata.title,
                                                      label: "export folder name"))
                ?? metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        case 2: folder = customFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        default: folder = nil
        }
        return ExportRequest(parentDestination: parent, subfolderName: folder,
                             filenamePattern: filenamePattern, wantTIFF: wantTIFF,
                             wantJPEG: wantJPEG, cropExport: cropExport, metadata: metadata,
                             frameNumbers: frameNumbers)
    }

    var problem: String? {
        if folderChoice == 2 && customFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name for the export folder."
        }
        if folderChoice == 1 {
            do { _ = try ExportNaming.safeComponent(metadata.title, label: "export folder name") }
            catch { return error.localizedDescription }
        }
        do { try request.validateOutputs(originalNames: originalNames); return nil }
        catch { return error.localizedDescription }
    }

    var example: String {
        guard let name = originalNames.first,
              let stem = try? ExportNaming.stem(pattern: filenamePattern,
                                                metadata: metadata,
                                                frame: request.frameNumber(at: 0),
                                                originalName: name) else { return "—" }
        return stem + (wantTIFF ? ".tif" : ".jpg")
    }
}

@MainActor
private struct ExportDialogView: View {
    @ObservedObject var draft: ExportDraft
    @StateObject private var patternEditor = ExportPatternEditor()
    let cancel: () -> Void
    let accept: () -> Void

    var body: some View {
        let problem = draft.problem
        VStack(spacing: 0) {
            HStack {
                Text("EXPORT PHOTOGRAPHS").font(FUI.small(true))
                Spacer()
                Text("\(draft.originalNames.count) FRAME\(draft.originalNames.count == 1 ? "" : "S")")
                    .font(FUI.small(true))
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(LinearGradient(colors: [FUI.tealTop, FUI.tealBot],
                                       startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { FUI.tealRule.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export to: \(draft.request.destination.path)")
                        .font(FUI.small())
                        .lineLimit(2).truncationMode(.middle)
                        .help(draft.request.destination.path)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Export folder").font(FUI.label(true))
                        HStack(spacing: 8) {
                            folderOption("Use chosen folder", choice: 0)
                            folderOption("Create roll title folder", choice: 1)
                            folderOption("Create custom folder", choice: 2)
                        }
                        if draft.folderChoice == 2 {
                            TextField("New folder name", text: $draft.customFolder)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    Divider()
                    Text("Filename pattern").font(FUI.label(true))
                    ExportPatternField(text: $draft.filenamePattern, editor: patternEditor)
                        .frame(height: 26)
                    Text("Insert a token at the cursor").font(FUI.small())
                        .foregroundStyle(FUI.ink.opacity(0.75))
                    HStack(spacing: 6) {
                        ForEach(ExportPatternTokens.choices) { choice in
                            Button(choice.title) {
                                patternEditor.insert(choice.token, into: $draft.filenamePattern)
                            }
                            .buttonStyle(Chunky(height: 28))
                            .help("Insert \(choice.token)")
                        }
                    }
                    Text("Example: \(draft.example)")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Divider()
                    HStack(spacing: 20) {
                        Toggle("16-bit TIFF", isOn: $draft.wantTIFF)
                        Toggle("JPEG", isOn: $draft.wantJPEG)
                    }
                    .toggleStyle(RollCheckboxStyle())
                    Toggle("Crop to detected frame", isOn: $draft.cropExport)
                        .toggleStyle(RollCheckboxStyle())
                    if let problem {
                        Text(problem).font(FUI.small()).foregroundStyle(FUI.inkRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(Chunky(height: 34, minWidth: 84))
                    .keyboardShortcut(.cancelAction)
                Button("Export", action: accept)
                    .buttonStyle(StartButton(height: 34, minWidth: 100))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .opacity(problem == nil ? 1 : 0.5)
            }
            .padding(12)
            .background(FUI.panelWell)
            .overlay(alignment: .top) { FUI.hiLight.frame(height: 1) }
        }
        .foregroundStyle(FUI.ink)
        .background(FUI.silver)
        .frame(width: 560, height: 560)
        .environment(\.colorScheme, .light)
    }

    private func folderOption(_ title: String, choice: Int) -> some View {
        Button(title) { draft.folderChoice = choice }
            .buttonStyle(Chunky(height: 34, lit: draft.folderChoice == choice))
            .accessibilityAddTraits(draft.folderChoice == choice ? .isSelected : [])
    }
}
