import Foundation
import ImageIO

/// Tests the import/export workflow models without starting SwiftUI.
final class WorkflowRegressionTests {
    private var scratch: URL {
        guard let path = ProcessInfo.processInfo.environment["HORIZON_TEST_TMP"] else {
            preconditionFailure("run Tests/run-invert-edge-tests.sh so fixtures stay in its cleaned temp directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func directory(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func run() throws {
        try metadataSurvivesCodingAndProducesPhotographicDescription()
        try metadataPersistsWithBackupAndUnreadableFilesArePreserved()
        try exportPatternsSubstituteAndSanitizeComponents()
        try exportValidationRejectsCollisionsBeforeCreatingDestination()
        try cacheManifestDistinguishesMissingIncompleteCompleteAndStale()
        rawExtensionRecognitionDoesNotNeedCameraFiles()
        try legacySessionPreservesItsAppliedCarrierState()
        singleShotFrameNumbersRemainPartOfTheSourceName()
        suggestLayoutAvoidsGuessingUnsuffixedTriples()
        try invalidAndForcedCacheMastersAreRebuilt()
        try partialRebuildsNeverMixSourceOrRecipeVersions()
        carrierMaskUsesRepeatedOpaqueGeometryAndRequiresThreeScans()
        try carrierAnalysisPersistsMasksWithoutTouchingMasters()
        try carrierMaskDefaultsAndPendingRecovery()
        photographDatesUseCalendarDays()
        try photographDatesPreservePrecision()
        filmSelectionDefaultsToBoxSpeedAndPreservesRatings()
        print("17 workflow regression tests passed")
    }

    private func filmSelectionDefaultsToBoxSpeedAndPreservesRatings() {
        var metadata = RollMetadata()
        metadata.selectFilmStock("Kodak Portra 400")
        precondition(metadata.boxISO == "400" && metadata.shootingEI == "400")
        metadata.selectFilmStock("Kodak Portra 160")
        precondition(metadata.boxISO == "160" && metadata.shootingEI == "160",
                     "a default EI follows the newly selected film")
        metadata.setShootingEI("800")
        metadata.selectFilmStock("CineStill 50D")
        precondition(metadata.boxISO == "50" && metadata.shootingEI == "800",
                     "an intentional exposure rating survives a film change")
        metadata.setShootingEI("")
        precondition(metadata.shootingEI == "50", "Box speed resets an explicit EI")
        metadata.selectFilmStock("Custom emulsion")
        precondition(metadata.boxISO.isEmpty && metadata.shootingEI.isEmpty,
                     "an unknown stock must not inherit the previous stock's speed")
        metadata.setBoxISO("64")
        precondition(metadata.shootingEI == "64")
        metadata.setShootingEI("125")
        metadata.setBoxISO("100")
        precondition(metadata.shootingEI == "125")

        var saved = RollMetadata(stock: "Kodak Vision3 500T", shootingEI: "800")
        saved.applyFilmDefaults()
        precondition(saved.boxISO == "500" && saved.shootingEI == "800")
        var defaults = RollMetadata(stock: "Fujicolor Pro 400H")
        defaults.applyFilmDefaults()
        precondition(defaults.boxISO == "400" && defaults.shootingEI == "400")
        defaults.setBoxISO("200")
        precondition(defaults.boxISO == "400", "a catalog film supplies its own box ISO")
        var custom = RollMetadata(stock: "Archived stock", boxISO: "80")
        custom.applyFilmDefaults()
        precondition(custom.boxISO == "80" && custom.shootingEI == "80")
    }

    private func photographDatesUseCalendarDays() {
        let zones = [TimeZone(secondsFromGMT: 14 * 3600)!, TimeZone(secondsFromGMT: -12 * 3600)!,
                     TimeZone(identifier: "Europe/Madrid")!]
        for zone in zones {
            for text in ["2024-02-29", "2026-03-29", "2026-10-25", "1999-12-31"] {
                guard let date = PhotoDate.parse(text, in: zone) else { preconditionFailure(text) }
                precondition(PhotoDate.serialize(date, in: zone) == text,
                             "a selected calendar day must not shift across time zones or daylight saving")
            }
            for text in ["", "September 2026", "2026-02-29", "2026-13-01", "2026-01-32", "2026-1-01"] {
                precondition(PhotoDate.parse(text, in: zone) == nil, "do not silently invent a date: \(text)")
            }
        }
    }

    private func photographDatesPreservePrecision() throws {
        let zones = [TimeZone(secondsFromGMT: 14 * 3600)!, TimeZone(secondsFromGMT: -12 * 3600)!,
                     TimeZone(identifier: "Europe/Madrid")!]
        let cases: [(String, PhotoDate.Precision)] = [
            ("2026", .year), ("1900", .year), ("2026-09", .month),
            ("2024-02", .month), ("2024-02-29", .day)
        ]
        for zone in zones {
            for (text, precision) in cases {
                guard let selection = PhotoDate.parseSelection(text, in: zone) else {
                    preconditionFailure(text)
                }
                precondition(selection.precision == precision)
                precondition(PhotoDate.serialize(selection.date, precision: precision, in: zone) == text,
                             "reopening a date must preserve its precision")
                if precision != .day {
                    precondition(PhotoDate.parse(text, in: zone) == nil,
                                 "partial dates must not be treated as known exact days")
                }
            }
            for text in ["", "September 2026", "2026-00", "2026-13", "2026-9", "0000", "2026-02-30"] {
                precondition(PhotoDate.parseSelection(text, in: zone) == nil, text)
            }
        }
        for text in ["2026", "2026-09"] {
            let metadata = RollMetadata(photographDate: text)
            let decoded = try JSONDecoder().decode(RollMetadata.self, from: JSONEncoder().encode(metadata))
            precondition(decoded.photographDate == text && decoded.summary == text)
            let name = try ExportNaming.stem(pattern: "{date}_{frame:03}", metadata: decoded,
                                             frame: 1, originalName: "scan.tif")
            precondition(name == text + "_001", "export names retain the selected precision")
            let props = decoded.imageProperties
            let iptc = props[kCGImagePropertyIPTCDictionary as String] as! [String: Any]
            precondition(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String
                         == "Photograph date: " + text)
            precondition(iptc[kCGImagePropertyIPTCDateCreated as String] == nil,
                         "export must not invent a day for a partial date")
            precondition(props[kCGImagePropertyExifDictionary as String] == nil)
        }
    }

    private func metadataSurvivesCodingAndProducesPhotographicDescription() throws {
        let metadata = RollMetadata(title: "Valencia", stock: "Portra 400", format: "35mm",
                                   boxISO: "400", shootingEI: "800", filmCamera: "Leica M6",
                                   filmLens: "50mm", photographDate: "2026-09-27",
                                   location: "El Cabanyal", developmentNotes: "C-41")
        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RollMetadata.self, from: encoded)
        precondition(decoded == metadata, "roll metadata must round trip")
        precondition(metadata.summary.contains("Portra 400")
                     && metadata.summary.contains("EI 800")
                     && metadata.summary.contains("Leica M6"), metadata.summary)

        let props = metadata.imageProperties
        guard let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] else {
            preconditionFailure("photographic title and location should be exported as IPTC")
        }
        precondition(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "Valencia")
        precondition(iptc[kCGImagePropertyIPTCSubLocation as String] as? String == "El Cabanyal")
        precondition(iptc[kCGImagePropertyIPTCDateCreated as String] as? String == "20260927",
                     "an exact photograph date should be exported as IPTC DateCreated")
        precondition(props[kCGImagePropertyExifDictionary as String] == nil,
                     "do not fabricate a time for a date-only film record")

        let legacy = try JSONDecoder().decode(RollMetadata.self, from: Data("{}".utf8))
        precondition(legacy == RollMetadata(), "metadata sidecars with missing fields stay readable")
    }

    private func metadataPersistsWithBackupAndUnreadableFilesArePreserved() throws {
        let workspace = try directory("metadata-persistence")
        let url = workspace.appendingPathComponent("metadata.json")
        let missing = try RollPersistence.loadMetadata(from: url)
        precondition(missing == RollMetadata())

        let first = RollMetadata(title: "Summer roll", stock: "Gold 200", location: "Valencia")
        try RollPersistence.saveMetadata(first, to: url)
        let loadedFirst = try RollPersistence.loadMetadata(from: url)
        precondition(loadedFirst == first)

        let second = RollMetadata(title: "Summer roll", stock: "Ektar 100", location: "Valencia")
        try RollPersistence.saveMetadata(second, to: url)
        let loadedSecond = try RollPersistence.loadMetadata(from: url)
        precondition(loadedSecond == second)
        let backup = try RollPersistence.loadMetadata(from: url.appendingPathExtension("backup"))
        precondition(backup == first, "the previous metadata sidecar should be recoverable")

        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        do {
            try RollPersistence.saveMetadata(second, to: url)
            preconditionFailure("a save must not replace an unreadable metadata file")
        } catch { }
        let preserved = try Data(contentsOf: url)
        precondition(preserved == corrupt, "a failed metadata save must preserve the original bytes")
    }

    private func exportPatternsSubstituteAndSanitizeComponents() throws {
        let metadata = RollMetadata(title: "Valencia", stock: "Portra/400",
                                    photographDate: "2026-09")
        let stem = try ExportNaming.stem(
            pattern: "{roll}_{stock}_{date}_{frame:03}_{original}",
            metadata: metadata, frame: 12, originalName: "capture_12R.tiff")
        precondition(stem == "Valencia_Portra-400_2026-09_012_capture_12R", stem)

        do {
            _ = try ExportNaming.stem(pattern: "{roll}_{filmcamera}", metadata: metadata,
                                      frame: 1, originalName: "capture.tif")
            preconditionFailure("an unknown filename token must be reported")
        } catch is ExportNaming.Problem { }

        do {
            _ = try ExportNaming.stem(pattern: "{frame:09}", metadata: metadata,
                                      frame: 1, originalName: "capture.tif")
            preconditionFailure("unsupported frame padding must be reported")
        } catch is ExportNaming.Problem { }

        let selected = ExportRequest(parentDestination: scratch, subfolderName: nil,
                                     filenamePattern: "{frame:03}", wantTIFF: true,
                                     wantJPEG: false, cropExport: false, metadata: metadata,
                                     frameNumbers: [29])
        precondition(selected.frameNumber(at: 0) == 29)
        let selectedStem = try selected.checkedStem(for: selected.frameNumber(at: 0),
                                                    originalName: "capture_29.tif")
        precondition(selectedStem == "029", selectedStem)
        do {
            try selected.validateOutputs(originalNames: ["capture_29.tif", "another.tif"])
            preconditionFailure("frame number and selection lengths must match")
        } catch is ExportNaming.Problem { }
    }

    private func exportValidationRejectsCollisionsBeforeCreatingDestination() throws {
        let parent = try directory("export-validation")
        let metadata = RollMetadata(title: "Roll")
        let request = ExportRequest(parentDestination: parent, subfolderName: "Roll exports",
                                    filenamePattern: "{roll}", wantTIFF: true,
                                    wantJPEG: false, cropExport: false, metadata: metadata)
        do {
            _ = try request.prepareDestination(originalNames: ["first.tif", "second.tif"])
            preconditionFailure("a pattern that maps multiple frames to one path must fail")
        } catch is ExportNaming.Problem { }
        precondition(!FileManager.default.fileExists(atPath: request.destination.path),
                     "failed validation must not create an export folder")

        let valid = ExportRequest(parentDestination: parent, subfolderName: "Roll exports",
                                  filenamePattern: "{roll}_{frame:03}", wantTIFF: true,
                                  wantJPEG: false, cropExport: false, metadata: metadata)
        let destination = try valid.prepareDestination(originalNames: ["first.tif", "second.tif"])
        precondition(destination == valid.destination)
        precondition(FileManager.default.fileExists(atPath: destination.path))

        let existing = destination.appendingPathComponent("Roll_001.tif")
        try Data([0]).write(to: existing)
        do {
            try valid.validateOutputs(originalNames: ["first.tif", "second.tif"])
            preconditionFailure("existing exports must be protected from accidental overwrite")
        } catch is ExportNaming.Problem { }
    }

    private func cacheManifestDistinguishesMissingIncompleteCompleteAndStale() throws {
        let root = try directory("manifest-fixture")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let source = captures.appendingPathComponent("frame.tif")
        try Data([1]).write(to: source)

        precondition(CacheManifest.status(captures: captures, cache: cache) == .absent)
        var manifest = CacheManifest(sourceStamp: try CacheManifest.stamp([source]),
                                     settingsStamp: "settings", layout: "rgb1",
                                     perFrameBase: true, useBorder: true,
                                     externalSources: [], externalSourceStamp: "",
                                     expected: ["frame"],
                                     completed: [])
        try manifest.write(cache: cache)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .incomplete)

        manifest.completed = ["frame"]
        manifest.finalized = true
        try manifest.write(cache: cache)
        try Invert.writeMaster([1000, 2000, 3000], w: 1, h: 1,
                               to: cache.appendingPathComponent("frame.ntg.tif"))
        var session = Invert.Session(layout: "rgb1")
        let sessionData = try JSONEncoder().encode(session)
        try sessionData.write(to: Invert.sessionURL(beside: cache), options: .atomic)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete)

        session.layout = "rgb3"
        try JSONEncoder().encode(session).write(to: Invert.sessionURL(beside: cache), options: .atomic)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .stale,
                     "a recipe that does not match the session must be flagged stale")
        session.layout = "rgb1"
        try JSONEncoder().encode(session).write(to: Invert.sessionURL(beside: cache), options: .atomic)

        try Data([1, 2]).write(to: source)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .stale,
                     "changed source bytes must invalidate the committed cache")

        try Data("not json".utf8).write(to: CacheManifest.url(cache: cache))
        precondition(CacheManifest.status(captures: captures, cache: cache) == .stale,
                     "a cache with masters and a corrupt manifest must be flagged stale")
    }

    private func rawExtensionRecognitionDoesNotNeedCameraFiles() {
        precondition(CaptureDecoder.isSupported(URL(fileURLWithPath: "/no-such-file/scan.CR3")))
        precondition(CaptureDecoder.isRAW(URL(fileURLWithPath: "/no-such-file/scan.DNG")))
        precondition(CaptureDecoder.isSupported(URL(fileURLWithPath: "/no-such-file/scan.tiff")))
        precondition(!CaptureDecoder.isRAW(URL(fileURLWithPath: "/no-such-file/scan.tiff")))
        precondition(!CaptureDecoder.isSupported(URL(fileURLWithPath: "/no-such-file/scan.jpeg")))
    }

    private func singleShotFrameNumbersRemainPartOfTheSourceName() {
        let oneShot = [URL(fileURLWithPath: "/captures/frame_1.tif")]
        precondition(Invert.captureStem(oneShot) == "frame_1",
                     "a numeric suffix in a single-shot filename is part of its name")

        let trichromatic = ["frame_1R.tif", "frame_1G.tif", "frame_1B.tif"]
            .map { URL(fileURLWithPath: "/captures/\($0)") }
        precondition(Invert.captureStem(trichromatic) == "frame",
                     "a trichromatic channel suffix belongs to the frame group")
    }

    private func suggestLayoutAvoidsGuessingUnsuffixedTriples() {
        let threeUnsuffixed = ["scan-a.raw", "scan-b.raw", "scan-c.raw"]
            .map { URL(fileURLWithPath: "/captures/\($0)") }
        precondition(Invert.suggestLayout(threeUnsuffixed)?.layout == .rgb1,
                     "three unsuffixed scans may be three photos, so suggest one capture per frame")

        let thirtySixUnsuffixed = (0..<36).map {
            URL(fileURLWithPath: "/captures/frame-\($0).raw")
        }
        precondition(Invert.suggestLayout(thirtySixUnsuffixed)?.layout == .rgb1,
                     "a normal 36-frame roll must not be inferred as twelve trichromatic frames")

        let explicit = ["frame_r.raw", "frame_g.raw", "frame_b.raw"]
            .map { URL(fileURLWithPath: "/captures/\($0)") }
        precondition(Invert.suggestLayout(explicit)?.layout == .rgb3,
                     "explicit complete channel labels identify a trichromatic set")
    }

    private func writeCapture(_ name: String, in folder: URL, width: Int = 128,
                              height: Int = 96, seed: Int) throws {
        var rgb = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let base = 4000 + (x * 317 + y * 521 + seed * 1703) % 50000
                let at = (y * width + x) * 3
                rgb[at] = UInt16(base)
                rgb[at + 1] = UInt16(min(base + 1200, 65535))
                rgb[at + 2] = UInt16(max(base - 700, 1))
            }
        }
        try Invert.writeMaster(rgb, w: width, h: height,
                               to: folder.appendingPathComponent(name + ".tif"))
    }

    private func invalidAndForcedCacheMastersAreRebuilt() throws {
        let root = try directory("master-recovery")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        let cache = root.appendingPathComponent("Horizon/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeCapture("frame", in: captures, seed: 1)

        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete)
        let master = cache.appendingPathComponent("frame.ntg.tif")

        try Data().write(to: master)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .incomplete)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete)

        try Data("not a TIFF".utf8).write(to: master)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .incomplete)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: master.path)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true,
                       out: cache, forceRebuild: true)
        let modified = try FileManager.default.attributesOfItem(atPath: master.path)[.modificationDate] as? Date
        precondition((modified?.timeIntervalSince1970 ?? 0) > 1,
                     "forceRebuild must rewrite a valid cache master")
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete)
    }

    private func partialRebuildsNeverMixSourceOrRecipeVersions() throws {
        let root = try directory("coherent-rebuild")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        let cache = root.appendingPathComponent("Horizon/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeCapture("frame-a", in: captures, seed: 1)
        try writeCapture("frame-b", in: captures, seed: 2)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete)

        try writeCapture("frame-a", in: captures, width: 136, height: 96, seed: 3)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache,
                       only: ["frame-a"])
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete,
                     "source changes cannot leave an old and new master mixed")

        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache,
                       only: ["frame-a"], useBorder: false)
        precondition(CacheManifest.status(captures: captures, cache: cache) == .complete,
                     "recipe changes cannot leave an old and new master mixed")
    }

    private func legacySessionPreservesItsAppliedCarrierState() throws {
        let oldData = Data(#"{"layout":"rgb1","frameBorders":{}}"#.utf8)
        let old = try JSONDecoder().decode(Invert.Session.self, from: oldData)
        precondition(!old.carrierMaskEnabled && old.carrierBorders.isEmpty
                     && old.pendingCarrierMaskEnabled == nil,
                     "a legacy cache with no carrier fields must retain its saved off state")

        let current = Invert.Session(layout: "rgb1", carrierBorders: [
            "frame": Invert.Border(left: 10, top: 3, right: 12, bottom: 4)
        ], carrierMaskEnabled: true)
        let data = try JSONEncoder().encode(current)
        let roundTrip = try JSONDecoder().decode(Invert.Session.self, from: data)
        precondition(roundTrip.carrierMaskEnabled
                     && roundTrip.carrierBorders["frame"] == current.carrierBorders["frame"])
    }

    private func carrierMaskUsesRepeatedOpaqueGeometryAndRequiresThreeScans() {
        let w = 1024, h = 512
        func synthetic(left: Int, right: Int, top: Int, bottom: Int) -> [[Float]] {
            var planes = [[Float]](repeating: [Float](repeating: 0.5, count: w * h), count: 3)
            for y in 0..<h {
                for x in 0..<w where x < left || x >= w - right || y < top || y >= h - bottom {
                    let i = y * w + x
                    for c in 0..<3 { planes[c][i] = 3.0 }
                }
            }
            return planes
        }

        var samples: [String: CarrierMask.Sample] = [:]
        for name in ["a", "b", "c"] {
            samples[name] = CarrierMask.sample(synthetic(left: 100, right: 80, top: 40, bottom: 40),
                                               w: w, h: h)
        }
        let ordinary = Dictionary(uniqueKeysWithValues: samples.keys.map { ($0, Invert.Border()) })
        let mask = CarrierMask.borders(samples: samples, detected: ordinary)
        guard let estimated = mask["a"] else {
            preconditionFailure("three matching scans with a wide opaque carrier should produce a beta mask")
        }
        precondition((95...120).contains(estimated.left), "wide left carrier estimate: \(estimated.left)")
        precondition((75...100).contains(estimated.right), "wide right carrier estimate: \(estimated.right)")
        precondition((35...60).contains(estimated.top), "top carrier estimate: \(estimated.top)")

        // Beta only supplements edges that the ordinary detector missed. It
        // must not replace or extend an existing detector result, even when
        // the repeated opaque geometry is wider.
        let ordinaryWithPartialDetection = Dictionary(uniqueKeysWithValues: samples.keys.map {
            ($0, Invert.Border(left: 12, top: 8, right: 0, bottom: 0))
        })
        let supplemental = CarrierMask.borders(samples: samples, detected: ordinaryWithPartialDetection)
        guard let supplements = supplemental["a"] else {
            preconditionFailure("Beta should supplement zero-detection sides")
        }
        precondition(supplements.left == 0 && supplements.top == 0,
                     "Beta must leave sides with any ordinary detection alone")
        precondition(supplements.right > 0 && supplements.bottom > 0,
                     "Beta may supplement sides where ordinary detection found zero")

        let twoScans = CarrierMask.borders(samples: ["a": samples["a"]!, "b": samples["b"]!],
                                           detected: ordinary)
        precondition(twoScans.isEmpty, "fewer than three scans must not activate roll-level estimates")

        samples["c"] = CarrierMask.sample(synthetic(left: 0, right: 0, top: 0, bottom: 0),
                                           w: w, h: h)
        let disagreement = CarrierMask.borders(samples: samples, detected: ordinary)
        precondition(disagreement.isEmpty, "unrepeated edges must not be masked across the roll")
    }

    private func carrierMaskDefaultsAndPendingRecovery() throws {
        let root = try directory("carrier-default-policy")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        for (index, name) in ["frame-a", "frame-b", "frame-c"].enumerated() {
            try writeCapture(name, in: captures, seed: index + 1)
        }

        // A new full inversion enables Beta without manufacturing debug images.
        let defaultCache = root.appendingPathComponent("default/Horizon/cache", isDirectory: true)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: defaultCache)
        precondition(Invert.loadSession(beside: defaultCache)?.carrierMaskEnabled == true,
                     "a fresh full inversion applies Beta by default")
        precondition(!FileManager.default.fileExists(atPath:
            defaultCache.deletingLastPathComponent().appendingPathComponent("debug/borders").path),
                     "ordinary inversion must not generate diagnostic images")

        // The API still allows an explicit opt-out. Selected and full rebuilds
        // preserve the saved choice unless a new request explicitly changes it.
        let cache = root.appendingPathComponent("explicit-off/Horizon/cache", isDirectory: true)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache,
                       carrierMaskEnabled: false)
        precondition(Invert.loadSession(beside: cache)?.carrierMaskEnabled == false,
                     "an explicit API opt-out is saved on the cache")
        var selected = 0
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache,
                       only: ["frame-a"], progress: { if $0.hasPrefix("inverting ") { selected += 1 } })
        precondition(selected == 1 && Invert.loadSession(beside: cache)?.carrierMaskEnabled == false,
                     "selected-frame work preserves a saved off cache")
        var rebuilt = 0
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: cache,
                       forceRebuild: true,
                       progress: { if $0.hasPrefix("inverting ") { rebuilt += 1 } })
        precondition(rebuilt == 3, "a full run must rebuild all frames when explicitly requested")
        precondition(Invert.loadSession(beside: cache)?.carrierMaskEnabled == false,
                     "a full rebuild preserves a saved off choice")

        // Pending ON and OFF requests remain separate from the applied state.
        // Selected work is rejected; cancellation retains both values until a
        // whole-roll retry commits the requested setting.
        let recoveryCache = root.appendingPathComponent("recovery/Horizon/cache", isDirectory: true)
        try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: recoveryCache,
                       carrierMaskEnabled: false)
        for (applied, requested) in [(false, true), (true, false)] {
            var session = Invert.loadSession(beside: recoveryCache)!
            session.carrierMaskEnabled = applied
            session.pendingCarrierMaskEnabled = requested
            try RollPersistence.write(session, to: Invert.sessionURL(beside: recoveryCache))
            do {
                try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: recoveryCache,
                               only: ["frame-a"])
                preconditionFailure("a pending roll-wide choice must reject selected-frame rebuilding")
            } catch {
                precondition(error.localizedDescription.contains("whole roll"))
            }
            let cancellation = RollCancellation()
            do {
                try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: recoveryCache,
                               forceRebuild: true, cancellation: { cancellation.isCancelled },
                               progress: { if $0.hasPrefix("inverting ") { cancellation.cancel() } })
                preconditionFailure("cancelled carrier recovery must stop")
            } catch {
                let retained = Invert.loadSession(beside: recoveryCache)!
                precondition(retained.carrierMaskEnabled == applied
                             && retained.pendingCarrierMaskEnabled == requested,
                             "cancellation keeps applied state and requested recovery choice")
            }
            var rebuiltPending = 0
            try Invert.run(dir: captures, layout: .rgb1, perFrameBase: true, out: recoveryCache,
                           forceRebuild: true,
                           progress: { if $0.hasPrefix("inverting ") { rebuiltPending += 1 } })
            let recovered = Invert.loadSession(beside: recoveryCache)!
            precondition(rebuiltPending == 3 && recovered.carrierMaskEnabled == requested
                         && recovered.pendingCarrierMaskEnabled == nil,
                         "a successful whole-roll retry commits the request and clears pending state")
        }
    }

    private func carrierAnalysisPersistsMasksWithoutTouchingMasters() throws {
        let root = try directory("carrier-analysis")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        let cache = root.appendingPathComponent("Horizon/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let w = 1024, h = 256, left = 100, right = 80
        let carrier = UInt16((pow(10.0, -3.0) * 65535).rounded())
        let picture = UInt16((pow(10.0, -0.5) * 65535).rounded())
        for name in ["scan-a", "scan-b", "scan-c"] {
            var rgb = [UInt16](repeating: picture, count: w * h * 3)
            for y in 0..<h {
                for x in 0..<w where x < left || x >= w - right {
                    let pixel = (y * w + x) * 3
                    rgb[pixel] = carrier; rgb[pixel + 1] = carrier; rgb[pixel + 2] = carrier
                }
            }
            try Invert.writeMaster(rgb, w: w, h: h,
                                   to: captures.appendingPathComponent(name + ".tif"))
        }

        let sentinel = cache.appendingPathComponent("scan-a.ntg.tif")
        let originalMaster = Data("master must not change during analysis".utf8)
        try originalMaster.write(to: sentinel)
        let sessionURL = Invert.sessionURL(beside: cache)
        let encoder = JSONEncoder()
        try encoder.encode(Invert.Session(layout: "rgb1")).write(to: sessionURL)

        let originalSession = try Data(contentsOf: sessionURL)
        let candidate = try Invert.analyzeCarrier(dir: captures, layout: .rgb1, out: cache, persist: false)
        let uncommitted = try Data(contentsOf: sessionURL)
        precondition(!candidate.isEmpty && uncommitted == originalSession,
                     "analysis inside a rebuild must not commit the carrier setting early")

        let result = try Invert.analyzeCarrier(dir: captures, layout: .rgb1, out: cache)
        guard let border = result["scan-a"] else {
            preconditionFailure("parallel carrier analysis should persist a repeated wide band")
        }
        precondition((95...120).contains(border.left), "persisted left carrier inset: \(border.left)")
        precondition((75...100).contains(border.right), "persisted right carrier inset: \(border.right)")
        let persisted = Invert.loadSession(beside: cache)
        precondition(persisted?.carrierMaskEnabled == true
                     && persisted?.carrierBorders["scan-a"] == border)
        let unchanged = try Data(contentsOf: sentinel)
        precondition(unchanged == originalMaster, "carrier analysis must not rewrite cached masters")
    }
}
