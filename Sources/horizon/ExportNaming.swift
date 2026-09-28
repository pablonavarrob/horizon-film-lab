import Foundation

enum ExportNaming {
    static let defaultPattern = "{roll}_{frame:03}"
    static let supportedTokens = "{roll}, {stock}, {date}, {frame:03}, {original}"

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Frame is one-based. Unknown braces are errors, so mistyped tokens can
    /// never quietly become part of filenames.
    static func stem(pattern: String, metadata: RollMetadata,
                     frame: Int, originalName: String) throws -> String {
        let input = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw Problem(message: "Enter a filename pattern.") }
        guard frame > 0 else { throw Problem(message: "Frame numbers start at 1.") }
        let original = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        var output = ""
        var cursor = input.startIndex
        while cursor < input.endIndex {
            if input[cursor] == "{" {
                guard let close = input[cursor...].firstIndex(of: "}") else {
                    throw Problem(message: "A filename token is missing its closing brace.")
                }
                let token = String(input[input.index(after: cursor)..<close])
                let value: String
                switch token {
                case "roll": value = metadata.title
                case "stock": value = metadata.stock
                case "date": value = metadata.photographDate
                case "original": value = original
                case "frame": value = String(frame)
                default:
                    if token.hasPrefix("frame:") {
                        let spec = String(token.dropFirst(6))
                        guard spec.first == "0", spec.count <= 3,
                              let digits = Int(spec), digits >= 1, digits <= 6 else {
                            throw Problem(message: "Use {frame:03} for a padded frame number.")
                        }
                        value = String(format: "%0*d", digits, frame)
                    } else {
                        throw Problem(message: "Unknown token {\(token)}. Use \(supportedTokens).")
                    }
                }
                output += value
                cursor = input.index(after: close)
            } else if input[cursor] == "}" {
                throw Problem(message: "A filename token has an extra closing brace.")
            } else {
                output.append(input[cursor])
                cursor = input.index(after: cursor)
            }
        }
        return try safeComponent(output, label: "filename")
    }

    static func safeComponent(_ input: String, label: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\u{0000}")
        let value = input.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, value != ".", value != ".." else {
            throw Problem(message: "The \(label) is empty. Add a title, original name, or frame number.")
        }
        guard value.utf8.count <= 220 else {
            throw Problem(message: "The \(label) is too long.")
        }
        return value
    }
}

struct ExportRequest {
    let parentDestination: URL
    let subfolderName: String?
    let filenamePattern: String
    let wantTIFF: Bool
    let wantJPEG: Bool
    let cropExport: Bool
    let metadata: RollMetadata
    /// Number within the roll for each exported frame. Selected-only exports
    /// retain the selected frame's number rather than restarting at one.
    let frameNumbers: [Int]?

    init(parentDestination: URL, subfolderName: String?, filenamePattern: String,
         wantTIFF: Bool, wantJPEG: Bool, cropExport: Bool, metadata: RollMetadata,
         frameNumbers: [Int]? = nil) {
        self.parentDestination = parentDestination; self.subfolderName = subfolderName
        self.filenamePattern = filenamePattern; self.wantTIFF = wantTIFF
        self.wantJPEG = wantJPEG; self.cropExport = cropExport
        self.metadata = metadata; self.frameNumbers = frameNumbers
    }

    var destination: URL {
        if let subfolderName { return parentDestination.appendingPathComponent(subfolderName) }
        return parentDestination
    }

    /// `frame` is one-based in both the filename and the API.
    func stem(for frame: Int, originalName: String) -> String {
        // The dialog and prepareDestination validate every stem first. A bad
        // pattern cannot get this far; keeping this nonthrowing eases export jobs.
        (try? ExportNaming.stem(pattern: filenamePattern, metadata: metadata,
                                frame: frame, originalName: originalName)) ?? "frame_\(frame)"
    }

    func checkedStem(for frame: Int, originalName: String) throws -> String {
        try ExportNaming.stem(pattern: filenamePattern, metadata: metadata,
                              frame: frame, originalName: originalName)
    }

    func frameNumber(at index: Int) -> Int { frameNumbers?[index] ?? index + 1 }

    func validateOutputs(originalNames: [String]) throws {
        guard wantTIFF || wantJPEG else {
            throw ExportNaming.Problem(message: "Choose TIFF, JPEG, or both.")
        }
        guard !originalNames.isEmpty else {
            throw ExportNaming.Problem(message: "There are no frames to export.")
        }
        if let frameNumbers {
            guard frameNumbers.count == originalNames.count,
                  frameNumbers.allSatisfy({ $0 > 0 }) else {
                throw ExportNaming.Problem(message: "Export frame numbers do not match the selected photographs.")
            }
        }
        if let subfolderName {
            let checked = try ExportNaming.safeComponent(subfolderName, label: "export folder name")
            guard checked == subfolderName else {
                throw ExportNaming.Problem(message: "The export folder name contains unsupported characters.")
            }
        }
        let fm = FileManager.default
        var parentIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parentDestination.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw ExportNaming.Problem(message: "The chosen export location is no longer available.")
        }
        var destinationIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
           !destinationIsDirectory.boolValue {
            throw ExportNaming.Problem(message: "The export folder name is already used by a file.")
        }
        var seen = Set<String>()
        let existing: Set<String> = Set(((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        for (index, originalName) in originalNames.enumerated() {
            let name = try ExportNaming.stem(pattern: filenamePattern, metadata: metadata,
                                             frame: frameNumber(at: index), originalName: originalName)
            for ext in [wantTIFF ? "tif" : nil, wantJPEG ? "jpg" : nil].compactMap({ $0 }) {
                let filename = "\(name).\(ext)"
                let key = filename.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                           locale: .current)
                guard seen.insert(key).inserted else {
                    throw ExportNaming.Problem(message: "The filename pattern gives more than one frame the name \(filename). Add {frame:03} or {original}.")
                }
                guard !existing.contains(key) else {
                    throw ExportNaming.Problem(message: "\(filename) already exists in the export folder. Choose another name or folder.")
                }
            }
        }
    }

    /// Validates all names before creating the optional subfolder.
    func prepareDestination(originalNames: [String]) throws -> URL {
        try validateOutputs(originalNames: originalNames)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)
        return destination
    }
}
