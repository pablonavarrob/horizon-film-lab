import AppKit
import Foundation
import ImageIO

/// Exercises the export dialog's draft state without opening any AppKit UI.
@MainActor
func runExportDialogTests() throws {
    guard let scratchPath = ProcessInfo.processInfo.environment["HORIZON_TEST_TMP"] else {
        preconditionFailure("run the regression harness so export fixtures stay in its cleaned temp directory")
    }
    let scratch = URL(fileURLWithPath: scratchPath, isDirectory: true)
    let root = scratch.appendingPathComponent("export-dialog-\(UUID().uuidString)",
                                               isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let parent = root.appendingPathComponent("chosen-location", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let metadata = RollMetadata(title: "Valencia", stock: "Portra 400", format: "35mm",
                                photographDate: "2026-09-28", location: "El Cabanyal")
    let originalNames = ["negative-29.tif"]

    // Each folder choice is reflected in the request and remains within the
    // location selected by the operator.
    let destinations = ExportDraft(metadata: metadata, parent: parent,
        originalNames: originalNames, wantTIFF: true, wantJPEG: false,
        cropExport: false, frameNumbers: [29])
    destinations.folderChoice = 0
    precondition(destinations.request.destination.standardizedFileURL.path
                 == parent.standardizedFileURL.path)
    precondition(destinations.request.subfolderName == nil)
    precondition(destinations.problem == nil)
    destinations.folderChoice = 1
    let rollFolder = parent.appendingPathComponent("Valencia", isDirectory: true)
    precondition(destinations.request.destination.standardizedFileURL.path
                 == rollFolder.standardizedFileURL.path)
    precondition(destinations.request.subfolderName == "Valencia")
    precondition(destinations.problem == nil)
    destinations.folderChoice = 2
    destinations.customFolder = "Proof Prints"
    let customFolder = parent.appendingPathComponent("Proof Prints", isDirectory: true)
    precondition(destinations.request.destination.standardizedFileURL.path
                 == customFolder.standardizedFileURL.path)
    precondition(destinations.problem == nil)

    // Invalid custom folder input reports a problem and becomes valid as soon
    // as the user supplies a usable value.
    destinations.customFolder = "   "
    precondition(destinations.problem != nil)
    destinations.customFolder = "Recovered Folder"
    precondition(destinations.problem == nil)
    precondition(destinations.request.destination.lastPathComponent == "Recovered Folder")

    // Format and crop controls flow into the immutable request; selected-only
    // exports use the frame's number from the full roll.
    precondition(destinations.request.wantTIFF && !destinations.request.wantJPEG
                 && !destinations.request.cropExport)
    precondition(destinations.request.frameNumber(at: 0) == 29)
    precondition(destinations.example == "Valencia_029.tif", destinations.example)
    destinations.wantTIFF = false
    destinations.wantJPEG = true
    destinations.cropExport = true
    precondition(!destinations.request.wantTIFF && destinations.request.wantJPEG
                 && destinations.request.cropExport)
    precondition(destinations.example == "Valencia_029.jpg", destinations.example)
    let selectedStem = try destinations.request.checkedStem(
        for: destinations.request.frameNumber(at: 0), originalName: originalNames[0])
    precondition(selectedStem == "Valencia_029", selectedStem)

    // Turning both formats off blocks export, and restoring one recovers
    // without creating the selected destination folder as a side effect.
    let recoveredFolder = parent.appendingPathComponent("Recovered Folder", isDirectory: true)
    destinations.wantJPEG = false
    precondition(destinations.problem != nil)
    precondition(!FileManager.default.fileExists(atPath: recoveredFolder.path))
    destinations.wantJPEG = true
    precondition(destinations.problem == nil)
    precondition(!FileManager.default.fileExists(atPath: recoveredFolder.path))

    // An existing filename blocks export, but changing the pattern clears the
    // error without changing or deleting the existing photograph.
    destinations.folderChoice = 0
    destinations.wantTIFF = true
    destinations.wantJPEG = false
    destinations.cropExport = false
    destinations.filenamePattern = ExportNaming.defaultPattern
    let collision = parent.appendingPathComponent("Valencia_029.tif")
    try Data("existing export".utf8).write(to: collision)
    let oldExport = try Data(contentsOf: collision)
    precondition(destinations.problem != nil)
    destinations.filenamePattern = "{roll}_{frame:03}_{original}"
    precondition(destinations.problem == nil)
    precondition(tryData(contentsOf: collision) == oldExport)

    // An invalid roll title must remain an invalid subfolder request. It must
    // never silently switch to exporting into the parent directory.
    let invalidParent = root.appendingPathComponent("invalid-title-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidParent, withIntermediateDirectories: true)
    let invalid = ExportDraft(metadata: RollMetadata(title: ".."), parent: invalidParent,
        originalNames: ["frame.tif"], wantTIFF: true, wantJPEG: false,
        cropExport: false, frameNumbers: [1])
    precondition(invalid.folderChoice == 1)
    precondition(invalid.problem != nil)
    precondition(invalid.request.subfolderName == "..")
    precondition(invalid.request.destination.standardizedFileURL.path
                 != invalidParent.standardizedFileURL.path)
    do {
        _ = try invalid.request.prepareDestination(originalNames: invalid.originalNames)
        preconditionFailure("an invalid roll-title folder must block export")
    } catch is ExportNaming.Problem { }
    let invalidParentContents = try FileManager.default.contentsOfDirectory(atPath: invalidParent.path)
    precondition(invalidParentContents.isEmpty)

    // Exercise FrameItem's real export path and inspect both generated files.
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let width = 64, height = 48
    var pixels = [UInt16](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let value = 2500 + ((x * 613 + y * 887) % 56000)
            let at = (y * width + x) * 3
            pixels[at] = UInt16(value)
            pixels[at + 1] = UInt16(min(value + 900, 65535))
            pixels[at + 2] = UInt16(max(value - 600, 1))
        }
    }
    let masterURL = cache.appendingPathComponent("scan_029.ntg.tif")
    try Invert.writeMaster(pixels, w: width, h: height, to: masterURL)
    let originalMaster = try Data(contentsOf: masterURL)
    let frame = FrameItem(url: masterURL)
    let frameNames = [frame.name + ".tif"]
    let exportDraft = ExportDraft(metadata: metadata, parent: parent,
        originalNames: frameNames, wantTIFF: true, wantJPEG: true,
        cropExport: false, frameNumbers: [29])
    exportDraft.folderChoice = 2
    exportDraft.customFolder = "Delivered Roll"
    exportDraft.filenamePattern = "{roll}_{frame:03}"
    precondition(exportDraft.problem == nil, exportDraft.problem ?? "")
    let request = exportDraft.request
    let destination = try request.prepareDestination(originalNames: frameNames)
    let stem = try request.checkedStem(for: request.frameNumber(at: 0),
                                       originalName: frameNames[0])
    precondition(stem == "Valencia_029", stem)
    let term = Master.Terminator(icc: nil, lut: nil, mono: false)
    try frame.export(Edit(), frame: nil, gate: nil, to: destination,
                     tiff: request.wantTIFF, jpeg: request.wantJPEG,
                     cropToFrame: request.cropExport, term: term,
                     outputStem: stem, metadata: metadata.imageProperties)

    let tiffURL = destination.appendingPathComponent(stem + ".tif")
    let jpegURL = destination.appendingPathComponent(stem + ".jpg")
    precondition(FileManager.default.fileExists(atPath: tiffURL.path))
    precondition(FileManager.default.fileExists(atPath: jpegURL.path))
    for output in [tiffURL, jpegURL] {
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let iptc = properties[kCGImagePropertyIPTCDictionary] as? NSDictionary else {
            preconditionFailure("photographic metadata missing from \(output.lastPathComponent)")
        }
        precondition(iptc[kCGImagePropertyIPTCObjectName] as? String == "Valencia")
        precondition(iptc[kCGImagePropertyIPTCSubLocation] as? String == "El Cabanyal")
        precondition(iptc[kCGImagePropertyIPTCDateCreated] as? String == "20260928")
    }
    precondition(tryData(contentsOf: masterURL) == originalMaster,
                 "export must leave its cached master unchanged")
    print("export dialog regression tests passed")
}

@MainActor
private func tryData(contentsOf url: URL) -> Data {
    do { return try Data(contentsOf: url) }
    catch { preconditionFailure("cannot read \(url.lastPathComponent): \(error)") }
}
