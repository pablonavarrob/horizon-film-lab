import Foundation
import ImageIO

/// Describes the photograph on film, rather than the digital capture of it.
struct RollMetadata: Codable, Equatable {
    var title = ""
    var stock = ""
    var format = ""
    var boxISO = ""
    var shootingEI = ""
    var filmCamera = ""
    var filmLens = ""
    /// YYYY, YYYY-MM, or YYYY-MM-DD; legacy free text remains readable.
    var photographDate = ""
    var location = ""
    var developmentNotes = ""

    init(title: String = "", stock: String = "", format: String = "",
         boxISO: String = "", shootingEI: String = "", filmCamera: String = "",
         filmLens: String = "", photographDate: String = "", location: String = "",
         developmentNotes: String = "") {
        self.title = title; self.stock = stock; self.format = format
        self.boxISO = boxISO; self.shootingEI = shootingEI
        self.filmCamera = filmCamera; self.filmLens = filmLens
        self.photographDate = photographDate; self.location = location
        self.developmentNotes = developmentNotes
    }

    private enum CodingKeys: String, CodingKey {
        case title, stock, format, boxISO, shootingEI, filmCamera, filmLens
        case photographDate, location, developmentNotes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        stock = try values.decodeIfPresent(String.self, forKey: .stock) ?? ""
        format = try values.decodeIfPresent(String.self, forKey: .format) ?? ""
        boxISO = try values.decodeIfPresent(String.self, forKey: .boxISO) ?? ""
        shootingEI = try values.decodeIfPresent(String.self, forKey: .shootingEI) ?? ""
        filmCamera = try values.decodeIfPresent(String.self, forKey: .filmCamera) ?? ""
        filmLens = try values.decodeIfPresent(String.self, forKey: .filmLens) ?? ""
        photographDate = try values.decodeIfPresent(String.self, forKey: .photographDate) ?? ""
        location = try values.decodeIfPresent(String.self, forKey: .location) ?? ""
        developmentNotes = try values.decodeIfPresent(String.self, forKey: .developmentNotes) ?? ""
    }

    private var followsBoxSpeed: Bool {
        shootingEI.isEmpty || shootingEI == boxISO
    }

    /// Apply defaults to the dialog draft, leaving a saved non-box rating intact.
    mutating func applyFilmDefaults() {
        let follows = followsBoxSpeed
        if let inferred = FilmStockCatalog.boxISO(for: stock) { boxISO = inferred }
        if follows { shootingEI = boxISO }
    }

    mutating func selectFilmStock(_ value: String) {
        guard value != stock else { return }
        let follows = followsBoxSpeed
        stock = value
        // An unknown stock needs its own speed; do not inherit the previous film's.
        boxISO = FilmStockCatalog.boxISO(for: value) ?? ""
        if follows { shootingEI = boxISO }
    }

    mutating func setBoxISO(_ value: String) {
        let follows = followsBoxSpeed
        boxISO = FilmStockCatalog.boxISO(for: stock)
            ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
        if follows { shootingEI = boxISO }
    }

    mutating func setShootingEI(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        shootingEI = value.isEmpty ? boxISO : value
    }

    var summary: String {
        [stock, format, shootingEI.isEmpty ? "" : "EI \(shootingEI)",
         filmCamera, photographDate, location]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Compact identifiers shown beside the capture-folder name in Recent
    /// Orders. Partial and exact photographic dates contribute only a year;
    /// invalid legacy free text is omitted rather than guessed or rewritten.
    var recentOrderSummary: String {
        let dateText = photographDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = PhotoDate.parseSelection(dateText).map { _ in String(dateText.prefix(4)) } ?? ""
        return [stock, filmCamera, year]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// ImageIO properties added to exported photographs. No scanner camera,
    /// digitisation date, or capture EXIF is inferred from source files.
    var imageProperties: [String: Any] {
        var iptc: [String: Any] = [:]
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { iptc[kCGImagePropertyIPTCObjectName as String] = name }
        if !location.isEmpty { iptc[kCGImagePropertyIPTCSubLocation as String] = location }
        if !stock.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = [stock] }
        if let date = Self.iptcDate(photographDate) {
            iptc[kCGImagePropertyIPTCDateCreated as String] = date
        }

        let caption = ["Film: \(stock)", "Format: \(format)", "Box ISO: \(boxISO)",
                       "Exposed at EI: \(shootingEI)", "Camera: \(filmCamera)",
                       "Lens: \(filmLens)", "Photograph date: \(photographDate)",
                       "Location: \(location)", "Development: \(developmentNotes)"]
            .filter { !$0.hasSuffix(": ") }.joined(separator: " | ")
        if !caption.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String] = caption }

        var result: [String: Any] = [:]
        if !iptc.isEmpty { result[kCGImagePropertyIPTCDictionary as String] = iptc }
        if !caption.isEmpty {
            result[kCGImagePropertyTIFFDictionary as String] =
                [kCGImagePropertyTIFFImageDescription as String: caption]
        }
        return result
    }

    private static func iptcDate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // IPTC DateCreated needs a full day. Partial dates remain in the
        // photographic caption rather than inventing a month or day for them.
        guard PhotoDate.parse(trimmed, in: TimeZone(secondsFromGMT: 0)!) != nil else { return nil }
        return trimmed.replacingOccurrences(of: "-", with: "")
    }
}
