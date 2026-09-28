import AppKit
import SwiftUI

/// Tests the text replacement used by the export token buttons without
/// opening a window or writing an export fixture.
@MainActor
func runExportPatternTests() throws {
    let choices = ExportPatternTokens.choices
    precondition(choices.map(\.title) == [
        "Roll name", "Film stock", "Date", "Frame number", "Original name"
    ])
    precondition(choices.map(\.token) == [
        "{roll}", "{stock}", "{date}", "{frame:03}", "{original}"
    ])

    let append = ExportPatternTokens.inserting("{frame:03}", into: "proof_",
                                               replacing: nil)
    precondition(append.text == "proof_{frame:03}" && append.caret == 16)

    let insertion = ExportPatternTokens.inserting("{stock}", into: "roll--frame",
                                                  replacing: NSRange(location: 5, length: 0))
    precondition(insertion.text == "roll-{stock}-frame" && insertion.caret == 12)

    let replacement = ExportPatternTokens.inserting("{date}", into: "A📷B",
                                                    replacing: NSRange(location: 1, length: 2))
    precondition(replacement.text == "A{date}B" && replacement.caret == 7,
                 "Selection replacement must use Cocoa's UTF-16 offsets")

    let outOfBounds = ExportPatternTokens.inserting("{roll}", into: "x",
                                                   replacing: NSRange(location: 999, length: 999))
    precondition(outOfBounds.text == "x{roll}" && outOfBounds.caret == 7)

    var typed = "custom-X_end"
    let editor = ExportPatternEditor()
    let binding = Binding<String>(get: { typed }, set: { typed = $0 })
    editor.remember(NSRange(location: 7, length: 1))
    editor.insert("{original}", into: binding)
    precondition(typed == "custom-{original}_end")
    editor.insert("{date}", into: binding)
    precondition(typed == "custom-{original}{date}_end",
                 "Repeated clicks should insert after the previous token")

    let metadata = RollMetadata(title: "Valencia", stock: "Kodak Gold 200",
                                photographDate: "2026-09")
    let draft = ExportDraft(metadata: metadata, parent: FileManager.default.temporaryDirectory,
                            originalNames: ["scan-29.tif"], wantTIFF: true, wantJPEG: false,
                            cropExport: false, frameNumbers: [29])
    precondition(draft.example == "Valencia_029.tif")
    draft.filenamePattern = choices.map(\.token).joined(separator: "_")
    let expected = "Valencia_Kodak Gold 200_2026-09_029_scan-29.tif"
    precondition(draft.example == expected,
                 "The live example must resolve all inserted tokens using roll frame 29")
    let resolved = try ExportNaming.stem(pattern: draft.filenamePattern,
                                         metadata: metadata, frame: 29,
                                         originalName: "scan-29.tif")
    precondition(resolved + ".tif" == expected)
    print("export token insertion tests passed")
}
