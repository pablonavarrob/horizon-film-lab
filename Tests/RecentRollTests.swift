import Foundation

/// Covers recent-order metadata snapshots without starting SwiftUI or touching
/// the user's recent-roll preferences.
final class RecentRollTests {
    private var scratch: URL {
        guard let path = ProcessInfo.processInfo.environment["HORIZON_TEST_TMP"] else {
            preconditionFailure("run the regression harness so fixtures stay in its cleaned temp directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @MainActor
    func run() throws {
        let root = scratch.appendingPathComponent("recent-rolls-\(UUID().uuidString)",
                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        metadataSummaryUsesPhotographicFieldsAndOmitsBlanks()
        try missingSidecarIsReadOnlyAndLoadedMetadataIsSnapshotted(in: root)
        try corruptSidecarStaysUnavailableAndUnchanged(in: root)
        try metadataOnlySavesPreserveActiveAndLegacyWorkspaces(in: root)
        print("recent roll regression tests passed")
    }

    private func metadataSummaryUsesPhotographicFieldsAndOmitsBlanks() {
        let metadata = RollMetadata(title: "Summer roll", stock: " Portra 400 ",
                                    format: "35mm", boxISO: "400", shootingEI: "800",
                                    filmCamera: " Leica M6 ", photographDate: " 2026-09-28 ",
                                    location: "Valencia")
        precondition(metadata.recentOrderSummary == "Portra 400 · Leica M6 · 2026",
                     metadata.recentOrderSummary)
        for date in ["2026", "2026-09", "2026-09-28"] {
            let dated = RollMetadata(stock: "Gold 200", filmCamera: "Olympus OM-1",
                                     photographDate: date)
            precondition(dated.recentOrderSummary == "Gold 200 · Olympus OM-1 · 2026",
                         "valid date precision should show only the year: \(dated.recentOrderSummary)")
        }
        let legacyDate = RollMetadata(stock: "Kentmere 400", filmCamera: "Pentax K1000",
                                      photographDate: "September 2026")
        precondition(legacyDate.recentOrderSummary == "Kentmere 400 · Pentax K1000",
                     "unparseable legacy date text must not produce a guessed year")
        precondition(RollMetadata(stock: " ", filmCamera: "\n", photographDate: "2026-13")
            .recentOrderSummary.isEmpty)
        precondition(RollMetadata().recentOrderSummary.isEmpty)
    }

    private func missingSidecarIsReadOnlyAndLoadedMetadataIsSnapshotted(in root: URL) throws {
        let captures = root.appendingPathComponent("missing-sidecar-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let missing = RecentRoll(url: captures)
        precondition(missing.metadata == nil && missing.metadataIssue == nil)
        precondition(missing.title == "missing-sidecar-roll")
        precondition(missing.subtitle.isEmpty)
        let untouchedContents = try FileManager.default.contentsOfDirectory(atPath: captures.path)
        precondition(untouchedContents.isEmpty,
                     "reading a recent roll must not create a workspace or sidecar")

        let workspace = Workspace(anyOf: captures)
        try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
        let saved = RollMetadata(title: "Summer roll", stock: "Portra 400", format: "35mm",
                                 shootingEI: "800", filmCamera: "Leica M6",
                                 photographDate: "2026-09-28", location: "Valencia")
        try JSONEncoder().encode(saved).write(to: workspace.metadata)
        let loaded = RecentRoll(url: captures)
        precondition(loaded.metadata == saved)
        precondition(loaded.title == captures.lastPathComponent,
                     "Recent Orders keeps the actual capture-folder name as its primary label")
        precondition(loaded.subtitle == "Portra 400 · Leica M6 · 2026", loaded.subtitle)
        precondition(loaded.tooltip.contains(captures.path))
        precondition(loaded.tooltip.contains("Title: Summer roll"))
        precondition(loaded.tooltip.contains("Photographic date: 2026-09-28"),
                     "the full saved date stays available in the tooltip")
    }

    private func corruptSidecarStaysUnavailableAndUnchanged(in root: URL) throws {
        let captures = root.appendingPathComponent("corrupt-sidecar-roll", isDirectory: true)
        let workspace = Workspace(anyOf: captures)
        try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
        let original = Data("broken metadata".utf8)
        try original.write(to: workspace.metadata)

        let roll = RecentRoll(url: captures)
        precondition(roll.metadata == nil)
        precondition(!(roll.metadataIssue ?? "").isEmpty)
        precondition(roll.title == "corrupt-sidecar-roll")
        precondition(roll.subtitle == "Metadata unavailable")
        let preserved = try Data(contentsOf: workspace.metadata)
        precondition(preserved == original,
                     "reading corrupt metadata must preserve its original bytes")
    }

    @MainActor
    private func metadataOnlySavesPreserveActiveAndLegacyWorkspaces(in root: URL) throws {
        // saveRecentMetadata refreshes the in-memory list, whose loader may
        // prune missing paths. Preserve the user's exact preference value so
        // this regression test never leaves recent-order defaults changed.
        let defaults = UserDefaults.standard
        let recentKey = "recentRolls"
        let originalRecentValue = defaults.object(forKey: recentKey)
        defer {
            if let originalRecentValue {
                defaults.set(originalRecentValue, forKey: recentKey)
            } else {
                defaults.removeObject(forKey: recentKey)
            }
        }

        let activeCaptures = root.appendingPathComponent("active-roll", isDirectory: true)
        let otherCaptures = root.appendingPathComponent("other-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: activeCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherCaptures, withIntermediateDirectories: true)
        let activeWorkspace = Workspace(anyOf: activeCaptures)
        let otherWorkspace = Workspace(anyOf: otherCaptures)
        try FileManager.default.createDirectory(at: activeWorkspace.cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherWorkspace.cache, withIntermediateDirectories: true)

        let originalActiveMetadata = RollMetadata(title: "Active order", stock: "Gold 200")
        let oldOtherMetadata = RollMetadata(title: "Other order", stock: "Ektar 100")
        try RollPersistence.saveMetadata(originalActiveMetadata, to: activeWorkspace.metadata)
        try RollPersistence.saveMetadata(oldOtherMetadata, to: otherWorkspace.metadata)

        let activeEdits = Data("active edits sentinel".utf8)
        let activeSession = Data("active session sentinel".utf8)
        let activeCache = Data("active cache sentinel".utf8)
        let otherEdits = Data("other edits sentinel".utf8)
        let otherSession = Data("other session sentinel".utf8)
        let otherCache = Data("other cache sentinel".utf8)
        try activeEdits.write(to: activeWorkspace.edits)
        try activeSession.write(to: activeWorkspace.session)
        let activeCacheFile = activeWorkspace.cache.appendingPathComponent("master.tif")
        try activeCache.write(to: activeCacheFile)
        try otherEdits.write(to: otherWorkspace.edits)
        try otherSession.write(to: otherWorkspace.session)
        let otherCacheFile = otherWorkspace.cache.appendingPathComponent("master.tif")
        try otherCache.write(to: otherCacheFile)

        let store = RollStore()
        store.workspace = activeWorkspace
        store.rollMetadata = originalActiveMetadata
        let frame = FrameItem(url: activeCacheFile)
        var originalEdit = Edit()
        originalEdit.cyan = 7
        originalEdit.density = 3
        frame.edit = originalEdit
        store.frames = [frame]

        let changedOtherMetadata = RollMetadata(title: "Other order revised", stock: "Portra 400",
                                                filmCamera: "Leica M6", photographDate: "2026-09-28")
        try store.saveRecentMetadata(changedOtherMetadata, for: otherCaptures)
        let savedOtherMetadata = try RollPersistence.loadMetadata(from: otherWorkspace.metadata)
        precondition(savedOtherMetadata == changedOtherMetadata)
        precondition(store.workspace?.captures.standardizedFileURL.path
                     == activeCaptures.standardizedFileURL.path)
        precondition(store.frames.count == 1 && store.frames[0] === frame)
        precondition(frame.edit == originalEdit)
        precondition(store.rollMetadata == originalActiveMetadata)
        let unchangedActiveMetadata = try RollPersistence.loadMetadata(from: activeWorkspace.metadata)
        precondition(unchangedActiveMetadata == originalActiveMetadata)
        try assertData(activeWorkspace.edits, equals: activeEdits)
        try assertData(activeWorkspace.session, equals: activeSession)
        try assertData(activeCacheFile, equals: activeCache)
        try assertData(otherWorkspace.edits, equals: otherEdits)
        try assertData(otherWorkspace.session, equals: otherSession)
        try assertData(otherCacheFile, equals: otherCache)

        let changedActiveMetadata = RollMetadata(title: "Active order revised", stock: "Vision3 500T",
                                                 filmCamera: "Nikon F3")
        try store.saveRecentMetadata(changedActiveMetadata, for: activeCaptures)
        precondition(store.rollMetadata == changedActiveMetadata,
                     "saving the active roll's details updates the visible header metadata")
        precondition(store.workspace?.captures.standardizedFileURL.path
                     == activeCaptures.standardizedFileURL.path)
        precondition(store.frames.count == 1 && store.frames[0] === frame)
        precondition(frame.edit == originalEdit)
        let savedActiveMetadata = try RollPersistence.loadMetadata(from: activeWorkspace.metadata)
        precondition(savedActiveMetadata == changedActiveMetadata)
        try assertData(activeWorkspace.edits, equals: activeEdits)
        try assertData(activeWorkspace.session, equals: activeSession)
        try assertData(activeCacheFile, equals: activeCache)

        let legacyCaptures = root.appendingPathComponent("legacy-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyCaptures, withIntermediateDirectories: true)
        let oldWorkspace = legacyCaptures.appendingPathComponent("Frontier", isDirectory: true)
        try FileManager.default.createDirectory(at: oldWorkspace, withIntermediateDirectories: true)
        let legacyWorkspace = Workspace(anyOf: legacyCaptures)
        precondition(legacyWorkspace.root.lastPathComponent == "Frontier")
        let legacyEdits = Data("legacy edits sentinel".utf8)
        let legacySession = Data("legacy session sentinel".utf8)
        let legacyCache = Data("legacy cache sentinel".utf8)
        try legacyEdits.write(to: legacyWorkspace.edits)
        try legacySession.write(to: legacyWorkspace.session)
        try FileManager.default.createDirectory(at: legacyWorkspace.cache, withIntermediateDirectories: true)
        let legacyCacheFile = legacyWorkspace.cache.appendingPathComponent("master.tif")
        try legacyCache.write(to: legacyCacheFile)
        let legacyMetadata = RollMetadata(title: "Legacy revised", stock: "Tri-X 400")
        try store.saveRecentMetadata(legacyMetadata, for: legacyCaptures)
        let savedLegacyMetadata = try RollPersistence.loadMetadata(from: legacyWorkspace.metadata)
        precondition(savedLegacyMetadata == legacyMetadata)
        precondition(!FileManager.default.fileExists(atPath:
            legacyCaptures.appendingPathComponent("Horizon").path),
                     "metadata for a legacy roll must stay in Frontier")
        try assertData(legacyWorkspace.edits, equals: legacyEdits)
        try assertData(legacyWorkspace.session, equals: legacySession)
        try assertData(legacyCacheFile, equals: legacyCache)

        let corruptCaptures = root.appendingPathComponent("corrupt-save-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptCaptures, withIntermediateDirectories: true)
        let corruptWorkspace = Workspace(anyOf: corruptCaptures)
        try FileManager.default.createDirectory(at: corruptWorkspace.root, withIntermediateDirectories: true)
        let corruptBytes = Data("do not replace me".utf8)
        try corruptBytes.write(to: corruptWorkspace.metadata)
        do {
            try store.saveRecentMetadata(RollMetadata(title: "Would overwrite"), for: corruptCaptures)
            preconditionFailure("saving metadata must refuse a corrupt existing sidecar")
        } catch { }
        try assertData(corruptWorkspace.metadata, equals: corruptBytes)

        let looseCaptures = root.appendingPathComponent("loose-master-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: looseCaptures, withIntermediateDirectories: true)
        let looseMetadata = RollMetadata(title: "Loose master metadata", stock: "HP5 Plus",
                                         filmCamera: "Olympus OM-1", photographDate: "2025-04")
        try store.saveRecentMetadata(looseMetadata, for: looseCaptures)
        let looseMaster = looseCaptures.appendingPathComponent("scan_001.ntg.tif")
        try Data("test master placeholder".utf8).write(to: looseMaster)
        store.openLoose(looseCaptures)
        precondition(store.workspace?.captures.standardizedFileURL.path
                     == looseCaptures.standardizedFileURL.path)
        precondition(store.rollMetadata == looseMetadata,
                     "opening legacy loose masters restores their photographic sidecar")
        _ = store.closeRoll()
    }

    private func assertData(_ url: URL, equals expected: Data) throws {
        let actual = try Data(contentsOf: url)
        precondition(actual == expected, "unexpected data at \(url.lastPathComponent)")
    }
}
